# vault_config

Terraform module that provisions all Vault configuration required by the three agentic use cases. Bridges the Vault deployment (Phase 3 Plan 01) to the agent workloads (Phases 4–6) by registering auth backends, secrets engines, policies, and roles inside a running Vault cluster. The audit device (PLAT-05) is also configured here so that every Vault API call — credential issuance, lease renewal, policy denial — flows as structured JSON to pod stdout for fluent-bit pickup.

## What this module configures

| Resource | Vault path | Requirement |
|---|---|---|
| Audit device (file → stdout, json) | — | PLAT-05 |
| Kubernetes auth backend | `kubernetes/` | CONF-01 |
| OAuth resource server activation flag | `sys/activation-flags/oauth-resource-server` | CONF-02 |
| OAuth resource server profile (IVIA) | `sys/config/oauth-resource-server/...` | CONF-02 |
| PostgreSQL secrets engine | `database/` | CONF-03 |
| AWS secrets engine (STS assumed_role) | `aws/` | CONF-04 |
| Policy: uc1-readonly | — | CONF-01, CONF-03 |
| Policy: uc2-personal | — | CONF-02, CONF-03, CONF-04 |
| Policy: uc3-refund-writer | — | CONF-02, CONF-03, CONF-04 |
| K8s role: uc1 | `kubernetes/role/uc1` | CONF-01 |
| K8s role: uc2 | `kubernetes/role/uc2` | CONF-01 |
| K8s role: uc3 | `kubernetes/role/uc3` | CONF-01 |

> **Native cutover (Phase 9, decision (e)):** the former `jwt/` auth backend and its
> `uc2-jwt`/`uc3-jwt` roles are RETIRED. IVIA's OAuth JWT now authorizes Vault
> directly via `X-Vault-Token` against the OAuth resource server profile — no
> `jwt_login` round-trip. The delegation/actor check the roles' `bound_claims`
> performed is re-homed natively to the RFC 8693 `act.sub` claim + Plan 05's actor
> alias; per-request scope moves to `vault:path_access` RAR.

## RDS password handling

The PostgreSQL secrets engine `connection_url` uses the RDS master password fetched at plan time from AWS Secrets Manager via `data.aws_secretsmanager_secret_version`. The ARN (`var.rds_master_user_secret_arn`) is wired from the `rds` component output `master_user_secret_arn`. The password is never stored as a plain Terraform variable or in state output — only in the Secrets Manager secret and the Vault connection config (encrypted at rest inside Vault's storage backend).

## PostgreSQL role design

| Vault role | Postgres grants | TTL | Use case |
|---|---|---|---|
| `uc1-readonly` | SELECT on all tables | 15 min / max 30 min | Use Case 1 — read-only data query agent |
| `uc2-personal` | SELECT on all tables | 15 min / max 30 min | Use Case 2 — personal data access agent |
| `uc3-refund-writer` | SELECT + INSERT + UPDATE | 5 min / max 10 min | Use Case 3 — refund processing agent (tightest scope) |

Creation statements include `VALID UNTIL '{{expiration}}'` so Postgres enforces the TTL independently of Vault lease expiry. Revocation statements drop the ephemeral role entirely (no residual access).

## OAuth resource server profile (replaces the JWT auth backend)

`vault_oauth_resource_server_config_profile.ivia` maps 1:1 onto the connection facts of
the retired IVIA jwt auth backend (issuer / JWKS / CA / audiences / RS256):

| Field | Value | Source |
|---|---|---|
| `profile_name` | `ivia` | required by provider 5.10.1 |
| `issuer_id` | `var.ivia_issuer` (immutable) | ← `bound_issuer` |
| `use_jwks` + `jwks_uri` | `true` + `var.ivia_jwks_url` | ← `jwks_url` |
| `jwks_ca_pem` | `var.ivia_oidc_ca_pem` | ← `jwks_ca_pem` |
| `audiences` | `["uc3-actor", "agent-uc2"]` | ← the retired roles' `bound_audiences` |
| `supported_algorithms` | `["RS256"]` | IVIA signs RS256 |
| `user_claim` | `sub` | extracts the SUBJECT (human `sub` UC3 / app `sub` UC2) |

One uniform profile serves both OAuth use cases (`USER_CLAIM_UNIFORM=yes`). `user_claim`
extracts the **subject**, never the agent — the AGENT is resolved by Vault's native
On-Behalf-Of handling of the RFC 8693 `act.sub` claim (IVIA emits it in Plan 04; Plan 05's
actor alias binds it). `optional_authorization_details` is deliberately NOT set on the
profile: it is a per-registration field (`OPT_AUTH_DETAILS_LEVEL=registration`), set by
Plan 05 (UC3 `false` = RAR mandatory; UC1/UC2 `true` = RAR optional). The
`vault_activation_flags` resource activates the `oauth-resource-server` feature first; the
profile `depends_on` it. The profile's server-assigned identifier is exported as
`oauth_resource_server_config_id` (the provider exposes it as the resource `id`).

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
| `ivia_issuer` | `string` | — | IVIA token issuer URL — `issuer_id` on the OAuth resource server profile |
| `ivia_jwks_url` | `string` | — | IVIA JWKS URL — `jwks_uri` on the profile |
| `ivia_oidc_ca_pem` | `string` | `""` | IVIA self-signed TLS CA PEM (sensitive) — `jwks_ca_pem` on the profile |
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
| `oauth_resource_server_config_id` | Server-assigned identifier of the IVIA OAuth resource server profile (provider `id`); Plan 05 derives the alias mount accessor from it |
| `database_mount_path` | Mount path of database secrets engine (`database`) |
| `aws_mount_path` | Mount path of AWS secrets engine (`aws`) |
| `uc1_role_name` | K8s auth role name for Use Case 1 (`uc1`) |
| `uc2_role_name` | K8s auth role name for Use Case 2 (`uc2`) |
| `uc3_role_name` | K8s auth role name for Use Case 3 (`uc3`) |

## Root module wiring

This module is consumed by the dedicated `infrastructure/vault-config/` root,
which runs AFTER tier-1 (`infrastructure/`) and tier-2 (`infrastructure/services/`)
have written their state. The root reads upstream outputs via
`data.terraform_remote_state` — the cross-tier read is itself the dependency
barrier, so no `depends_on` is needed. Vault server (`module.vault_server`) and
IVIA (`module.ivia`) live in tier-2; their outputs arrive through `local.services`.

```hcl
# infrastructure/vault-config/main.tf (excerpt)
data "terraform_remote_state" "root" {
  backend = "local"
  config  = { path = "../terraform.tfstate" }          # tier-1
}
data "terraform_remote_state" "services" {
  backend = "local"
  config  = { path = "../services/terraform.tfstate" } # tier-2 (vault_server + ivia)
}

locals {
  root     = data.terraform_remote_state.root.outputs
  services = data.terraform_remote_state.services.outputs
}

module "vault_config" {
  source = "../modules/vault_config"

  cluster_endpoint                   = local.root.cluster_endpoint
  cluster_certificate_authority_data = local.root.cluster_certificate_authority_data
  cluster_oidc_issuer                = local.root.cluster_oidc_issuer
  ivia_issuer                        = local.services.ivia_issuer
  ivia_oidc_ca_pem                   = local.services.ivia_oidc_ca_pem
  rds_endpoint                       = local.root.rds_endpoint
  rds_master_username                = local.root.rds_master_username
  rds_master_user_secret_arn         = local.root.rds_master_user_secret_arn
  bedrock_role_arn                   = local.root.bedrock_role_arn
  uc3_logs_role_arn                  = local.root.uc3_logs_role_arn
  region                             = local.root.region
}
```

## Pitfalls

**P1 — `verify_connection = false` on vault_database_secret_backend_connection**: Vault attempts a live DB connection during `terraform apply`. At apply time the RDS instance exists but may not yet have the Vault-initiated pgaudit extension or the `workshop` database schema. Set `verify_connection = false` to avoid spurious failures; the connection is validated at first credential issuance instead.

**P2 — `vault_kubernetes_auth_backend_config.kubernetes_ca_cert` must be PEM, not base64**: EKS outputs base64-encoded CA data. Wrap in `base64decode()` before passing to the config resource, otherwise the Kubernetes auth backend rejects login attempts with a TLS handshake error.

**P3 — `vault_oauth_resource_server_config_profile` requires `profile_name` and pins to provider ≥ 5.10.1**: `profile_name` is a REQUIRED argument in the provider schema (the recipe omits it); the resource and `vault_agent_registration` first appear in `hashicorp/vault` 5.10.1, so BOTH `hashicorp/vault` pins (this module + the `infrastructure/vault-config/` tier-2 root) must be bumped together to `>= 5.10.1, < 6.0.0` or the apply fails. The profile exposes its identifier as the computed `id` — there is no separate `config_id` attribute. The agent/delegation check is NOT a `bound_claims` glob anymore: it is Vault's native `act.sub` resolution, so IVIA must emit `act.sub` (NOT `may_act` — Plan 04) or native OBO fails closed.

**P4 — AWS secrets engine `role_arns` requires at least one entry for `assumed_role` credential type**: `role_arns` is wired to `var.bedrock_role_arn` (sourced from `module.bedrock_kb_aoss.kb_role_arn`). Leaving it empty causes `vault read aws/sts/bedrock-reader` to fail at runtime with a configuration error rather than an IAM error.

## References

- [HashiCorp Vault Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [HashiCorp Vault JWT/OIDC auth method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [HashiCorp Vault Database secrets engine — PostgreSQL](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)
- [HashiCorp Vault AWS secrets engine](https://developer.hashicorp.com/vault/docs/secrets/aws)
- [RFC 8693 — OAuth 2.0 Token Exchange (`may_act` claim)](https://datatracker.ietf.org/doc/html/rfc8693#section-4.4)
- [Vault Audit Devices](https://developer.hashicorp.com/vault/docs/audit)
