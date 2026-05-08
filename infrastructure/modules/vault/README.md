# Vault Module

Deploys HashiCorp Vault 2.0.0 on EKS via Helm chart 0.32.0 in a 3-node Raft HA configuration. Uses a dedicated KMS key for auto-unseal and Pod Identity for IAM (not IRSA). Audit events are written to stdout in JSON format for fluent-bit pickup.

## Architecture

```
EKS Cluster
└── namespace: vault
    ├── vault-0  (Raft leader)
    ├── vault-1  (Raft follower)
    └── vault-2  (Raft follower)
        ↑
        KMS auto-unseal (alias/vault-unseal — dedicated key, not workshop CMK)
        Pod Identity: SA "vault" → IAM role vault-kms-unseal → kms:Encrypt/Decrypt/DescribeKey
```

**Raft HA:** All three pods join via retry_join entries pointing to `vault-{0,1,2}.vault-internal:8200`. The Raft storage path is `/vault/data` on a 10 Gi gp2 PVC per pod.

**KMS auto-unseal:** A dedicated KMS key (`alias/vault-unseal`) is created by this module. It is intentionally separate from the workshop CMK (`alias/workshop-data`) so that CloudTrail decrypt calls for Vault unseal are distinguishable from storage encryption operations. This matters for audit-correlation in Phase 6.

**Audit logging:** Vault is started with `-log-format=json`. The audit device is configured in the `vault_config` module (Phase 3 Plan 02) to write to `/dev/stdout`. No PVC audit storage is used (`auditStorage.enabled = false`).

**Service account:** The Vault SA is created by this module's Pod Identity association. Helm is instructed `server.serviceAccount.create = false` to avoid a conflicting SA.

## Inputs

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `region` | `string` | yes | AWS region for KMS unseal key and Vault seal stanza. |
| `cluster_name` | `string` | yes | EKS cluster name — used for Pod Identity association and IAM role name prefix. |
| `cluster_endpoint` | `string` | yes | EKS API server endpoint (passed through for Stacks component provider config). |
| `cluster_certificate_authority_data` | `string` | yes | Base64-encoded cluster CA data (sensitive). |
| `oidc_provider_arn` | `string` | yes | OIDC provider ARN — retained for forward compatibility; Vault uses Pod Identity. |
| `audit_log_group_names` | `map(string)` | yes | Audit log group name map from the `audit` component (keys: vault-audit, ivia-decision, agent-trace). |
| `tags` | `map(string)` | no | Tags applied to all AWS resources. Default: `{}` |

## Outputs

| Name | Description |
|------|-------------|
| `vault_endpoint` | In-cluster Vault API URL: `http://vault.vault.svc.cluster.local:8200` |
| `vault_namespace` | Kubernetes namespace (`vault`). |
| `vault_service_account` | Vault pod service account name (`vault`). |
| `vault_unseal_kms_key_arn` | ARN of the dedicated KMS unseal key. |
| `vault_unseal_kms_key_id` | Key ID of the dedicated KMS unseal key. |

## Component Wiring

`components.tfcomponent.hcl` registers this module as the `vault` component in Wave 3:

```hcl
component "vault" {
  source = "./modules/vault"
  providers = {
    aws        = provider.aws.main
    helm       = provider.helm.main
    kubernetes = provider.kubernetes.main
  }
  inputs = {
    region                             = var.region
    cluster_name                       = component.eks.cluster_name
    cluster_endpoint                   = component.eks.cluster_endpoint
    cluster_certificate_authority_data = component.eks.cluster_certificate_authority_data
    oidc_provider_arn                  = component.eks.oidc_provider_arn
    audit_log_group_names              = component.audit.audit_log_group_names
    tags                               = var.tags
  }
}
```

The input references to `component.eks` and `component.audit` create implicit Wave 3 ordering — Stacks will not plan the vault component until both eks and audit are applied.

## Post-Deploy Steps

After the Terraform Stack applies successfully, an attendee must initialize Vault:

```bash
# Forward the vault-0 pod port (run from a kubectl-configured terminal)
kubectl -n vault port-forward vault-0 8200:8200 &

export VAULT_ADDR=http://127.0.0.1:8200

# Initialize — KMS auto-unseal means 0 key shares and 0 key threshold required
vault operator init -key-shares=1 -key-threshold=1

# Vault pods automatically unseal via KMS after init — no manual unseal needed
vault status
```

The root token printed during `vault operator init` should be stored securely. For workshop purposes it is used in Phase 3 Plan 02 (`vault_config`) to configure the PKI secrets engine and auth methods.

## Known Pitfalls

**H1 — Helm provider 3.x incompatibility:** The `helm` provider is pinned to `~> 2.17`. Helm 3.x changed the `set {}` block syntax in a breaking way. Do NOT bump to 3.x.

**V1 — Conflicting service account:** If `server.serviceAccount.create` is left at the default `true`, Helm creates a SA that conflicts with the one expected by the Pod Identity association. This module sets it to `false` and names the SA `vault` explicitly.

**V2 — Dedicated unseal key:** Vault's unseal key (`alias/vault-unseal`) must NOT be shared with the workshop CMK (`alias/workshop-data`). Reusing the same key merges CloudTrail decrypt events for unseal and storage operations, breaking the audit-correlation signal in Phase 6.

**V3 — KMS unseal key policy ordering:** The KMS key policy references `aws_iam_role.vault_kms.arn`. Terraform resolves this via the known ARN pattern before the role exists, so no explicit `depends_on` is required.

## References

- [HashiCorp Vault Helm chart 0.32.0 changelog](https://github.com/hashicorp/vault-helm/releases/tag/v0.32.0)
- [EKS Pod Identity documentation](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [Vault KMS auto-unseal — AWS](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms)
- [Vault Raft storage](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
