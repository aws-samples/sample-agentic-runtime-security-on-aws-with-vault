# vault_config

Terraform module that provisions all Vault configuration required by the three agentic use cases. Bridges the Vault deployment (Phase 3 Plan 01) to the agent workloads (Phases 4–6) by registering auth backends, secrets engines, policies, and roles inside a running Vault cluster. The audit device (PLAT-05) is also configured here so that every Vault API call — credential issuance, lease renewal, policy denial — flows as structured JSON to pod stdout for fluent-bit pickup.

## What this module configures

| Resource | Vault path | Requirement |
|---|---|---|
| Audit device (file → stdout, json) | — | PLAT-05 |
| Kubernetes auth backend | `kubernetes/` | CONF-01 |
| JWT auth backend (IVIA OIDC) | `jwt/` | CONF-02 |
| PostgreSQL secrets engine | `database/` | CONF-03 |
| AWS secrets engine (STS assumed_role) | `aws/` | CONF-04 |
| Policy: uc1-readonly | — | CONF-01, CONF-03 |
| Policy: uc2-personal | — | CONF-02, CONF-03, CONF-04 |
| Policy: uc3-refund-writer | — | CONF-02, CONF-03, CONF-04 |
| K8s role: uc1 | `kubernetes/role/uc1` | CONF-01 |
| K8s role: uc2 | `kubernetes/role/uc2` | CONF-01 |
| K8s role: uc3 | `kubernetes/role/uc3` | CONF-01 |
| JWT role: uc2-jwt | `jwt/role/uc2-jwt` | CONF-02 |
| JWT role: uc3-jwt | `jwt/role/uc3-jwt` | CONF-02 |

## RDS password handling

The PostgreSQL secrets engine `connection_url` uses the RDS master password fetched at plan time from AWS Secrets Manager via `data.aws_secretsmanager_secret_version`. The ARN (`var.rds_master_user_secret_arn`) is wired from the `rds` component output `master_user_secret_arn`. The password is never stored as a plain Terraform variable or in state output — only in the Secrets Manager secret and the Vault connection config (encrypted at rest inside Vault's storage backend).

## PostgreSQL role design

| Vault role | Postgres grants | TTL | Use case |
|---|---|---|---|
| `uc1-readonly` | SELECT on all tables | 15 min / max 30 min | Use Case 1 — read-only data query agent |
| `uc2-personal` | SELECT on all tables | 15 min / max 30 min | Use Case 2 — personal data access agent |
| `uc3-refund-writer` | SELECT + INSERT + UPDATE | 5 min / max 10 min | Use Case 3 — refund processing agent (tightest scope) |

Creation statements include `VALID UNTIL '{{expiration}}'` so Postgres enforces the TTL independently of Vault lease expiry. Revocation statements drop the ephemeral role entirely (no residual access).

## JWT auth role design

`uc2-jwt` — `bound_audiences=["agent-uc2"]`: standard OIDC audience check. Any IVIA-issued token with `aud=agent-uc2` may exchange for a Vault token carrying the `uc2-personal` policy.

`uc3-jwt` — `bound_claims={"may_act":"*"}`: enforces RFC 8693 delegation semantics. IVIA must mint a token with the `may_act` claim present (indicating the delegating user's subject). Vault rejects tokens without this claim, preventing unattended refund writes that bypass the user-consent gate.

## Audit device

```hcl
resource "vault_audit" "stdout" {
  type    = "file"
  options = { file_path = "stdout", format = "json" }
}
```

Vault writes one JSON object per API call to pod stdout. The fluent-bit DaemonSet (Phase 5) ships these to CloudWatch Logs `/vault/audit` where Phase 6 Athena JOINs correlate them with pgaudit, CloudTrail, and IVIA decision logs using the `trace_id` field.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `cluster_endpoint` | `string` | — | EKS API server URL |
| `cluster_certificate_authority_data` | `string` | — | Base64-encoded EKS CA cert (sensitive) |
| `cluster_oidc_issuer` | `string` | — | EKS OIDC issuer URL |
| `ivia_oidc_discovery_url` | `string` | — | IVIA OIDC discovery URL |
| `rds_endpoint` | `string` | — | RDS endpoint `<address>:<port>` |
| `rds_master_username` | `string` | `vault_root` | RDS master username |
| `rds_master_user_secret_arn` | `string` | — | Secrets Manager ARN for RDS master password (sensitive) |
| `rds_db_name` | `string` | `workshop` | Database name |
| `bedrock_role_arn` | `string` | — | IAM role ARN Vault assumes for scoped Bedrock STS credentials |
| `region` | `string` | — | AWS region for the AWS secrets engine |
| `tags` | `map(string)` | `{}` | Resource tags |

## Outputs

| Name | Description |
|---|---|
| `kubernetes_auth_path` | Mount path of Kubernetes auth backend (`kubernetes`) |
| `jwt_auth_path` | Mount path of JWT auth backend (`jwt`) |
| `database_mount_path` | Mount path of database secrets engine (`database`) |
| `aws_mount_path` | Mount path of AWS secrets engine (`aws`) |
| `uc1_role_name` | K8s auth role name for Use Case 1 (`uc1`) |
| `uc2_role_name` | K8s auth role name for Use Case 2 (`uc2`) |
| `uc3_role_name` | K8s auth role name for Use Case 3 (`uc3`) |
| `uc2_jwt_role_name` | JWT auth role name for Use Case 2 (`uc2-jwt`) |
| `uc3_jwt_role_name` | JWT auth role name for Use Case 3 (`uc3-jwt`) |

## Component wiring (Stacks)

```hcl
# infrastructure/deployments.tfdeploy.hcl (excerpt)
component "vault_config" {
  source  = "./modules/vault_config"
  version = "~> 1.0"

  inputs = {
    cluster_endpoint                    = component.eks.cluster_endpoint
    cluster_certificate_authority_data  = component.eks.cluster_certificate_authority_data
    cluster_oidc_issuer                 = component.eks.cluster_oidc_issuer
    ivia_oidc_discovery_url             = component.ivia.oidc_discovery_url
    rds_endpoint                        = component.rds.endpoint
    rds_master_username                 = component.rds.master_username
    rds_master_user_secret_arn          = component.rds.master_user_secret_arn
    rds_db_name                         = component.rds.db_name
    bedrock_role_arn                    = component.bedrock_kb_aoss.kb_role_arn
    region                              = var.region
    tags                                = var.tags
  }
}
```

## Pitfalls

**P1 — `verify_connection = false` on vault_database_secret_backend_connection**: Vault attempts a live DB connection during `terraform apply`. At Stacks plan/apply time the RDS instance exists but may not yet have the Vault-initiated pgaudit extension or the `workshop` database schema. Set `verify_connection = false` to avoid spurious failures; the connection is validated at first credential issuance instead.

**P2 — `vault_kubernetes_auth_backend_config.kubernetes_ca_cert` must be PEM, not base64**: EKS outputs base64-encoded CA data. Wrap in `base64decode()` before passing to the config resource, otherwise the Kubernetes auth backend rejects login attempts with a TLS handshake error.

**P3 — `vault_jwt_auth_backend_role.bound_claims` must be a flat `map(string)`**: The `may_act` claim in an RFC 8693 token is a JSON object, not a string. Vault evaluates `bound_claims` as string equality or glob — use `"may_act" = "*"` (glob) to require the claim is present without constraining its value. Never attempt to pass a nested object here.

**P4 — AWS secrets engine `role_arns` requires at least one entry for `assumed_role` credential type**: `role_arns` is wired to `var.bedrock_role_arn` (sourced from `component.bedrock_kb_aoss.kb_role_arn`). Leaving it empty causes `vault read aws/sts/bedrock-reader` to fail at runtime with a configuration error rather than an IAM error.

## References

- [HashiCorp Vault Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [HashiCorp Vault JWT/OIDC auth method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [HashiCorp Vault Database secrets engine — PostgreSQL](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)
- [HashiCorp Vault AWS secrets engine](https://developer.hashicorp.com/vault/docs/secrets/aws)
- [RFC 8693 — OAuth 2.0 Token Exchange (`may_act` claim)](https://datatracker.ietf.org/doc/html/rfc8693#section-4.4)
- [Vault Audit Devices](https://developer.hashicorp.com/vault/docs/audit)
