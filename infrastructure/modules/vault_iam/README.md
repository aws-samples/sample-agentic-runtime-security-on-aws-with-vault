# vault_iam Module — Vault IAM / KMS (tier 1)

Owns the **foundational identity + key material** for Vault, and nothing else. The Vault server runtime (namespace, ServiceAccount, Helm release) lives in the sibling [`vault_server`](../vault_server/README.md) module, deployed in tier 2 (shared services).

This split exists because Vault's IAM role is named as a **trusted principal** in the Bedrock Knowledge Base role's trust policy (`modules/bedrock_kb_aoss`), and AWS rejects an IAM trust policy that names a principal which does not yet exist. The role therefore must be created in the same (earlier) tier as the KB role — tier 1. The Vault server pods can come later.

## What this module creates

```
tier 1 (infrastructure/)
├── aws_kms_key.vault_unseal         (alias/vault-unseal — dedicated unseal key)
├── aws_iam_role.vault_kms           (<cluster_name>-vault-kms-unseal)
│     trust: pods.eks.amazonaws.com  (EKS Pod Identity, NOT IRSA)
│     policy: kms:Encrypt/Decrypt/DescribeKey on the unseal key
└── aws_eks_pod_identity_association.vault
      namespace=vault / service_account=vault → vault_kms role
```

**KMS unseal key:** A dedicated key (`alias/vault-unseal`), intentionally separate from the workshop CMK (`alias/workshop-data`) so that CloudTrail decrypt calls for Vault unseal stay distinguishable from storage encryption operations — this matters for audit-correlation in Phase 6 (Pitfall V2). Key rotation enabled; 7-day deletion window.

**Pod Identity association (name-based):** The association maps `namespace=vault` / `service_account=vault` to the unseal role. EKS Pod Identity associations are name-based and resolve **lazily** when a vault pod requests credentials — so the association is valid here in tier 1 even though the namespace + SA it points at are not created until tier 2 (`vault_server`). No cross-tier resource dependency is required; the structural tier-1→tier-2 ordering (enforced by `deploy-workshop.sh`) is sufficient.

## Inputs

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `cluster_name` | `string` | yes | EKS cluster name — used for the Pod Identity association and the KMS unseal IAM role name prefix. |
| `tags` | `map(string)` | no | Tags applied to all AWS resources. Default: `{}` |

## Outputs

| Name | Description |
|------|-------------|
| `vault_unseal_kms_key_arn` | ARN of the dedicated KMS unseal key. |
| `vault_unseal_kms_key_id` | Key ID of the unseal key. Read by `vault_server` (tier 2) to render the Vault `seal "awskms"` stanza. |
| `vault_iam_role_arn` | ARN of the Vault Pod Identity role. Trusted by the KB role / uc3-logs-writer trust policies. |
| `vault_iam_role_id` | ID of the Vault Pod Identity role. Used to attach the vault-assume policies in tier 1. |

## Root module wiring (tier 1)

```hcl
module "vault_iam" {
  source       = "./modules/vault_iam"
  cluster_name = module.eks.cluster_name
  tags         = var.tags
}
```

No `depends_on` is needed — the module only creates IAM + KMS + a Pod Identity association, none of which require the cluster's data plane or add-ons to be ready.

## Tier-1 consumers of this module's outputs

- `module.bedrock_kb_aoss` — `vault_iam_role_arns = [module.vault_iam.vault_iam_role_arn]` (KB-role trust).
- `aws_iam_role_policy.vault_assume_bedrock` — `role = module.vault_iam.vault_iam_role_id`.
- `aws_iam_role.uc3_logs_writer` — trust policy names `module.vault_iam.vault_iam_role_arn`.
- `aws_iam_role_policy.vault_assume_uc3_logs` — `role = module.vault_iam.vault_iam_role_id`.
- `module.vault_server` (tier 2, via remote_state) — `kms_key_id = ...vault_unseal_kms_key_id`.

## Known Pitfalls

**V2 — Dedicated unseal key:** Vault's unseal key (`alias/vault-unseal`) must NOT be shared with the workshop CMK (`alias/workshop-data`). Reusing the same key merges CloudTrail decrypt events for unseal and storage operations, breaking the audit-correlation signal in Phase 6.

**V3 — KMS key policy ordering:** The KMS key policy references `aws_iam_role.vault_kms.arn`. Terraform resolves this via the known ARN pattern, so no explicit `depends_on` is required.

## References

- [EKS Pod Identity documentation](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [Vault KMS auto-unseal — AWS](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms)
