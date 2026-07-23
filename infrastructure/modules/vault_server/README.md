# Vault Server Module — tier 2 (shared services)

Deploys the HashiCorp Vault **server runtime** on EKS: the `vault` namespace, the `vault` ServiceAccount, an autoloaded Enterprise license secret, and the Helm release (chart `hashicorp/vault` 0.32.0, image `hashicorp/vault-enterprise:2.0.3-ent`) in a 3-node Raft HA configuration with KMS auto-unseal.

**Enterprise, not community (Phase 9).** The server image was cut from community `hashicorp/vault:2.0.0` to `hashicorp/vault-enterprise:2.0.3-ent` to unlock the native Agent Registry + OAuth resource server primitives (Enterprise-only, license-gated). The Enterprise binary hard-fails `operator init` without an autoloaded license — `kubernetes_secret.vault_ent_license` (Opaque, key `license`) is wired into Helm `server.enterpriseLicense` so the license is present before the chart installs. The license itself is a per-attendee deploy input (`var.vault_enterprise_license`, sensitive, no default) — `deploy-workshop.sh` reads it from a license file (`VAULT_ENTERPRISE_LICENSE_PATH`, default `~/Downloads/vault-ent.hclic`) and writes it into the gitignored tier-2 `terraform.tfvars`; it is never a committed literal. The license MUST carry the `platform-standard` module (NOT `pki-only` — that is a *restriction* that blocks the `database`/`aws`/`kv`/`transit` mounts every use case depends on).

The foundational IAM role, KMS unseal key, and Pod Identity association live in the sibling [`vault`](../vault/README.md) module (tier 1) — see that README for *why* the split exists. This module receives the KMS key id via the tier-1 `terraform_remote_state` read and binds the Vault `seal "awskms"` stanza to it.

## Architecture

```
EKS Cluster
└── namespace: vault
    ├── vault-0  (Raft leader)
    ├── vault-1  (Raft follower)
    └── vault-2  (Raft follower)
        ↑
        KMS auto-unseal (alias/vault-unseal — created in tier 1)
        Pod Identity: SA "vault" → role <cluster>-vault-kms-unseal (association in tier 1)
```

**Raft HA:** All three pods join via retry_join entries pointing to `vault-{0,1,2}.vault-internal:8200`. The Raft storage path is `/vault/data` on a 10 Gi gp2 PVC per pod.

**Audit logging:** Vault is started with `-log-format=json`. The audit device is configured by the `vault-config` root (post-deploy) to write to `/dev/stdout`. No PVC audit storage is used (`auditStorage.enabled = false`).

**Service account:** The Vault SA is created by this module. Helm is instructed `server.serviceAccount.create = false` to avoid a conflicting SA (Pitfall V1). The tier-1 Pod Identity association maps this SA to the unseal IAM role.

## Inputs

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `region` | `string` | yes | AWS region — rendered into the Vault KMS seal stanza. |
| `kms_key_id` | `string` | yes | Key ID of the dedicated unseal key. From tier-1 output `vault_unseal_kms_key_id`. |
| `tags` | `map(string)` | no | Tags applied to taggable resources. Default: `{}` |
| `vault_enterprise_license` | `string` | yes | Vault Enterprise license (`.hclic` contents), sensitive. **No default** — identity/secret material must never have one. Sourced from a file by `deploy-workshop.sh`. |

## Outputs

| Name | Description |
|------|-------------|
| `vault_namespace` | Kubernetes namespace (`vault`). |
| `vault_service_account` | Vault pod service account name (`vault`). |
| `vault_endpoint` | In-cluster Vault API URL: `http://vault.vault.svc.cluster.local:8200` |

## Root module wiring (tier 2 — `infrastructure/services/`)

```hcl
module "vault_server" {
  source                   = "../modules/vault_server"
  region                   = var.region
  kms_key_id               = data.terraform_remote_state.infra.outputs.vault_unseal_kms_key_id
  tags                     = var.tags
  vault_enterprise_license = var.vault_enterprise_license
}
```

The kubernetes + helm providers in the tier-2 root are configured from the tier-1 remote_state EKS outputs (`cluster_endpoint`, `cluster_certificate_authority_data` + `aws eks get-token` exec).

## Post-Deploy — Two-phase bootstrap (handled by `deploy-workshop.sh`)

Vault starts sealed + uninitialized. KMS auto-unseal handles unsealing; initialization is a one-time operation performed by `vault-init.sh`:

```bash
kubectl exec -n vault vault-0 -- vault operator init -format=json
```

The root token is captured into the runtime environment and consumed by the `vault-config` root. It is **never** written to Terraform state.

## Known Pitfalls

**H1 — Helm provider 3.x incompatibility:** The `helm` provider is pinned to `~> 2.17`. Helm 3.x changed the `set {}` block syntax in a breaking way. Do NOT bump to 3.x.

**V1 — Conflicting service account:** If `server.serviceAccount.create` is left at the default `true`, Helm creates a SA that conflicts with the one the tier-1 Pod Identity association expects. This module sets it to `false` and names the SA `vault` explicitly.

**E1 — License module gating (Phase 9):** `pki-only` is a *restriction*, not an add-on — it blocks the `database`/`aws`/`kv`/`transit` engines every use case depends on. The attendee license MUST carry `platform-standard` (which bundles `agentic-iam`, unlocking Agent Registry + OAuth resource server) and MUST NOT carry `pki-only`. This module does not validate license module contents — that is a deploy-time live gate (`check-prerequisites.sh` checks only file presence; the live engine-mount assertion lands in a later Phase 9 plan).

## References

- [HashiCorp Vault Helm chart 0.32.0 changelog](https://github.com/hashicorp/vault-helm/releases/tag/v0.32.0)
- [Vault Raft storage](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- [Vault Enterprise license autoloading](https://developer.hashicorp.com/vault/docs/enterprise/license/autoloading)
