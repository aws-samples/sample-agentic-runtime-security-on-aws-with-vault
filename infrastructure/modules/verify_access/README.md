# Verify Access Module

Deploys IBM Verify Identity Access (IVIA) 11.0.2 OIDC provider on EKS using raw Kubernetes manifests via the `kubernetes_*` Terraform provider. There is no official Helm chart for IVIA — this module produces every required Kubernetes object directly so attendees can read the full configuration as Terraform code.

IVIA serves as the identity provider for user-context delegation (OAuth 2.0, CIBA, and Rich Authorization Requests). The Vault jwt auth method configured in Plan 03-03 consumes the OIDC discovery URL output from this module. Use Cases 2 and 3 depend on IVIA for user authentication flows.

## Architecture

```
                  ┌──────────────────────────────────────────────────────────┐
                  │  verify-access namespace                                  │
                  │                                                           │
                  │  ┌─────────────────┐      ┌──────────────────────────┐  │
  External OIDC   │  │  Ingress (ALB)   │      │  ConfigMap isvaop-config │  │
  Discovery ──────┼─▶│  internet-facing │      │  (OIDC + CIBA settings)  │  │
                  │  └────────┬────────┘      └──────────────────────────┘  │
                  │           │                         │ volume              │
                  │  ┌────────▼────────┐      ┌────────▼─────────────────┐  │
                  │  │  Service isvaop  │      │  Deployment isvaop       │  │
                  │  │  ClusterIP:8436  ├─────▶│  icr.io/ivia/ivia-oidc   │  │
  Vault jwt auth ─┼─▶│                 │      │  -provider:26.03          │  │
  (in-cluster)    │  └─────────────────┘      └──────────────────────────┘  │
                  │                                    │ volumes              │
                  │  ┌─────────────────────────────────▼─────────────────┐  │
                  │  │  Secrets: isvaop-server (RDS creds) + isvaop-obf   │  │
                  │  │  ICR pull secret: icr-pull-secret                  │  │
                  │  └────────────────────────────────────────────────────┘  │
                  └──────────────────────────────────────────────────────────┘
                                          │
                                          ▼ RDS PostgreSQL backend
                            (module.rds — workshop database)
```

- **Single OIDC provider deployment** — 1 replica, CPU 250m/1, memory 512Mi/1Gi
- **PostgreSQL backend** — RDS instance from `module.rds` (bootstrap creds from Secrets Manager; Vault rotates post-deploy)
- **ALB Ingress** — AWS Load Balancer Controller provisions an internet-facing ALB for external OIDC discovery endpoint access
- **Internal ClusterIP** — `isvaop.verify-access.svc.cluster.local:8436` for in-cluster consumers (Vault jwt auth, UC2/UC3 agents)

## Prerequisites

1. **IBM entitlement key** — Required for the ICR pull secret (Pitfall 3). Without this, pods enter `ImagePullBackOff`. Attendees obtain the key from the IBM Cloud console: `Manage → Account → IBM entitlement keys → Container Registry`.

2. **AWS Load Balancer Controller** — Must be deployed (`module.addons`) before IVIA for the ALB Ingress to be provisioned.

3. **Vault endpoint** — `module.vault.vault_endpoint` must exist before IVIA deploys, as it is referenced in IVIA configuration as the OIDC seam target.

## Inputs

| Name | Type | Sensitive | Description |
|------|------|-----------|-------------|
| `region` | `string` | no | AWS region. No literals — interpolated from `var.region`. |
| `cluster_name` | `string` | no | EKS cluster name for tagging. |
| `rds_endpoint` | `string` | no | Full RDS endpoint `<address>:<port>` from `module.rds.endpoint`. |
| `rds_address` | `string` | no | RDS hostname without port from `module.rds.address`. |
| `rds_port` | `number` | no | RDS port from `module.rds.port` (5432). |
| `rds_master_username` | `string` | no | RDS master username from `module.rds.master_username`. |
| `rds_master_user_secret_arn` | `string` | yes | Secrets Manager ARN for RDS master password (JSON: `username`/`password` keys). |
| `rds_db_name` | `string` | no | Database name from `module.rds.db_name` (`workshop`). |
| `vault_endpoint` | `string` | no | Vault ClusterIP URL from `module.vault.vault_endpoint`. |
| `audit_log_group_names` | `map(string)` | no | Audit log group names from `module.audit.audit_log_group_names`. |
| `icr_entitlement_key` | `string` | yes | IBM Container Registry entitlement key for image pull auth. |
| `tags` | `map(string)` | no | Tags applied to all AWS resources. Default: `{}`. |

## Outputs

| Name | Description |
|------|-------------|
| `ivia_oidc_discovery_url` | Internal OIDC discovery URL (ClusterIP path). Vault jwt auth method consumes this. Format: `https://isvaop.verify-access.svc.cluster.local:8436/.well-known/openid-configuration` |
| `ivia_namespace` | Kubernetes namespace (`verify-access`). |
| `ivia_service_endpoint` | ClusterIP service DNS without scheme. Format: `isvaop.verify-access.svc.cluster.local` |
| `ivia_ingress_hostname` | ALB hostname from LBC. May be empty until LBC reconciles the Ingress. |

## Root module wiring

`infrastructure/main.tf` calls this module as `module.ivia`:

```hcl
module "ivia" {
  source = "./modules/verify_access"

  depends_on = [module.addons, time_sleep.alb_webhook_ready]

  region                     = var.region
  cluster_name               = module.eks.cluster_name
  rds_endpoint               = module.rds.endpoint           # Pitfall 8: no rds_ prefix
  rds_address                = module.rds.address
  rds_port                   = module.rds.port
  rds_master_username        = module.rds.master_username
  rds_master_user_secret_arn = module.rds.master_user_secret_arn
  rds_db_name                = module.rds.db_name
  vault_endpoint             = module.vault.vault_endpoint
  audit_log_group_names      = module.audit.audit_log_group_names
  icr_entitlement_key        = var.icr_entitlement_key
  tags                       = var.tags
}
```

The `icr_entitlement_key` variable is declared in `infrastructure/variables.tf` and supplied as a sensitive HCP Terraform workspace variable.

## Post-Deploy Verification

After the workspace apply completes, verify the OIDC discovery endpoint returns valid JSON:

```bash
# Check pod is running
kubectl get pods -n verify-access

# Verify OIDC discovery URL responds (from within the cluster)
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -sk https://isvaop.verify-access.svc.cluster.local:8436/.well-known/openid-configuration | jq .

# Check ALB hostname (may take 2-3 minutes for LBC to provision)
kubectl get ingress -n verify-access
```

The discovery response must contain `"issuer"`, `"grant_types_supported"`, and `"jwks_uri"` fields.

## Known Issue — IVIA 25.10 ROPC + `scope=openid` (id_token generation crash)

**Affected version:** `icr.io/ivia/ivia-oidc-provider:25.10` (Go binary: `/app/ristretto`, Goja JS runtime)

**Symptom:** `grant_type=password` with `scope=openid` returns HTTP 500 (`FBTAQ5102E`). Without `openid`, the same request succeeds. Stack trace: `flow_resource_owner.go:51 → access_response_writer.go:28`.

**Root cause:** The ROPC flow authenticates the user against LDAP successfully, but does **not propagate the authenticated identity** (principalName, sub, AZN_CRED_PRINCIPAL_NAME) to the `pretoken` mapping rule. The pretoken context is completely empty — `stsuu.principalName` is `""`, `userData.uid` is `undefined`, `stsuu.ctxAttrs` is `{"ntmap":{}}`. When `scope=openid` triggers id_token (JWT) assembly, the response writer nil-dereferences on the missing `sub` claim.

**Key discovery:** Values set in the `ropc` mapping rule (via `userData.uid`, `stsuu.setPrincipalName()`, `stsuu.addAttribute()`) are **discarded** between the ropc and pretoken execution contexts. The two rules do NOT share state.

**Workaround (applied in this module):** The `pretoken` rule parses the `mappingrule_context` JSON string (a global available in the Goja runtime). This JSON contains the original ROPC body parameters including `username`. The pretoken rule extracts it and explicitly populates `stsuu.setPrincipalName()`, `stsuu.addAttribute()` for `sub` and `AZN_CRED_PRINCIPAL_NAME`, and `idtokenData.sub`/`tokenData.sub`.

**IVIA Goja JS runtime API (confirmed by runtime probing):**
- Available globals: `stsuu`, `userData`, `tokenData`, `idtokenData`, `claims`, `oauth_client`, `oauth_definition`, `Attribute` (constructor), `paramsOverride`, `headersOverride`, `cfgOverride`, `mappingrule_context` (JSON string)
- **NOT available** (despite IBM docs targeting traditional ISAM): `UserLookupHelper`, `OAuthMappingExtUtils`, `IDMappingExtUtils`, `importClass`, `Packages.com.tivoli.*`

**If upgrading IVIA:** Re-test ROPC + `scope=openid` without the pretoken workaround. If IBM fixes the identity propagation, the workaround can be removed — the pretoken rule guards with `if (!stsuu.principalName || stsuu.principalName === "")` so it's safe to leave in place.

## Pitfalls

**Pitfall 3 — ICR pull secret missing.** The IVIA image is hosted at `icr.io/ivia/ivia-oidc-provider`. Without the `icr-pull-secret` Kubernetes secret, pods enter `ImagePullBackOff`. This module creates the secret using `var.icr_entitlement_key` — the secret must be created before the Deployment reconciles. The `depends_on` block in `kubernetes_deployment.isvaop` ensures ordering.

**Pitfall 6 — Use `kubernetes_*` resources, not `kubectl_manifest`.** The `kubernetes` provider (hashicorp/kubernetes ~> 2.25) is already declared in `providers.tf`. Adding a separate `gavinbunney/kubectl` provider would introduce an extra provider dependency. All manifests in this module use `kubernetes_namespace`, `kubernetes_deployment`, `kubernetes_service`, `kubernetes_ingress_v1`, etc.

**Pitfall 8 — RDS output names have no `rds_` prefix.** The RDS module outputs are `endpoint`, `address`, `port`, `master_username`, `master_user_secret_arn`, `db_name` — NOT `rds_endpoint`, `rds_address`, etc. Use `module.rds.endpoint` (not `module.rds.rds_endpoint`) when wiring the ivia module in `main.tf`.
