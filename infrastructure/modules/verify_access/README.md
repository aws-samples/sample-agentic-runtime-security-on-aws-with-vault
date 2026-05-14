# Verify Access Module

Deploys IBM Verify Identity Access (IVIA) 11.0.2 full stack on EKS using raw Kubernetes manifests via the `kubernetes_*` Terraform provider. There is no official Helm chart for IVIA — this module produces every required Kubernetes object directly so attendees can read the full configuration as Terraform code.

IVIA serves as the identity provider for user-context delegation (OAuth 2.0, CIBA, and Rich Authorization Requests). Use Cases 2 and 3 depend on IVIA for user authentication flows. The Vault jwt auth method configured in Plan 03-03 consumes the OIDC discovery URL output from this module.

## Why the Full Stack?

The standalone `ivia-oidc-provider` is a token factory — it issues OAuth tokens, hosts JWKS endpoints, and executes JavaScript mapping rules. But it has **no authentication engine**. Without the full IVIA stack, CIBA consent flows (Use Case 3) cannot complete: the standalone OIDC Provider returns `404` for `/oauth2/ciba_user_authorize/{id}` because it expects the Web Reverse Proxy to handle all browser sessions.

The full stack adds Config, AAC Runtime, and WRP alongside the OIDC Provider to provide a complete authentication and authorization platform.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  verify-access namespace                                              │
│                                                                       │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────────┐ │
│  │  Config       │   │  AAC Runtime  │   │  WRP                     │ │
│  │  (LMI 9443)  │──▶│  (AAC 9443)  │   │  (Proxy 9443)            │ │
│  │  Publishes    │──▶│  Downloads   │   │  Downloads snapshot       │ │
│  │  snapshots    │   │  snapshot    │   │  from Config              │ │
│  └──────────────┘   └──────────────┘   └──────────┬───────────────┘ │
│                            │                        │ ALB Ingress     │
│                            │ LDAP validate          │ (internet-facing)│
│                            ▼                        │                 │
│                       Simple AD              ┌──────▼──────────────┐ │
│                                              │  OIDC Provider       │ │
│  ┌─────────────────────────────────────────▶│  (Token 8436)        │ │
│  │  Machine-to-machine                       │  ClusterIP only      │ │
│  │  (agent, Vault jwt auth)                  │  junction /isvaop    │ │
│  └─────────────────────────────────────────  └──────────────────────┘ │
│                                                        │               │
└──────────────────────────────────────────────────────────────────────┘
                                                         │
                                                         ▼ RDS PostgreSQL backend
                                             (module.rds — workshop database)
```

## Container Roles

| Container | Image | Port | Purpose |
|-----------|-------|------|---------|
| `ivia-config` | `icr.io/ivia/ivia-config:11.0.2.0` | 9443 | Local Management Interface (LMI). Stores configuration and publishes snapshots to WRP and Runtime. |
| `ivia-runtime` | `icr.io/ivia/ivia-runtime:11.0.2.0` | 9443 | Advanced Access Control (AAC) authentication engine. Validates credentials against Simple AD (LDAP). |
| `ivia-wrp` | `icr.io/ivia/ivia-wrp:11.0.2.0` | 9443 | Web Reverse Proxy. Browser-facing entry point. Handles login pages, session management, and junction routing to OIDC Provider. |
| `ivia-oidc-provider` | `icr.io/ivia/ivia-oidc-provider:25.10` | 8436 | OAuth 2.0 / OIDC token factory. Issues tokens, hosts JWKS, runs CIBA bc-authorize and token poll, executes JavaScript mapping rules. |

## Deployment Sequence

The `depends_on` chain in this module enforces this exact order:

```
1. Config container (ivia-config) starts
   └─ LMI available on ClusterIP :9443
   └─ All other containers depend on Config being ready

2. Autoconf Job (kubernetes_job.ivia_autoconf)
   └─ Image: python:3.12-slim
   └─ pip install ibmvia_autoconf
   └─ Activates modules: webseal + aac + federation (using ivia_activation_code)
   └─ Creates WRP instance "default"
   └─ Creates junction /isvaop -> isvaop.verify-access.svc.cluster.local:8436 (SSL)
   └─ Sets anyauth ACL on /isvaop/oauth2/ciba_user_authorize/*
   └─ Publishes configuration snapshot

3. Runtime (ivia-runtime) + WRP (ivia-wrp) start in parallel
   └─ Both download published snapshot from Config via CONFIG_SERVICE_URL
   └─ WRP ALB Ingress becomes the external browser entry point
```

## Traffic Routing

**Browser flows** (CIBA consent, authorization_code) → `Internet → ALB → WRP → OIDC Provider`

The WRP `/isvaop` junction proxies to the OIDC Provider. The `anyauth` ACL on `/isvaop/oauth2/ciba_user_authorize/*` forces login before the consent page renders. WRP delegates credential validation to AAC Runtime, which performs an LDAP bind against Simple AD.

**Machine-to-machine flows** (bc-authorize, CIBA token poll, ROPC, client_credentials, token exchange, Vault jwt auth) → `Agent/Vault → OIDC Provider ClusterIP (isvaop.verify-access.svc.cluster.local:8436)`

These flows do not require user authentication and bypass WRP entirely for lower latency and simpler routing.

## Activation Codes

The Config container requires activation codes to unlock the following modules:

| Module | Purpose |
|--------|---------|
| `webseal` | Enables the Web Reverse Proxy (WRP) functionality |
| `aac` | Enables Advanced Access Control (AAC) — the authentication engine |
| `federation` | Enables federation and OIDC capabilities |

- **Source:** IBM Passport Advantage, part number `M11DCML` — NOT the trial `.cer` file (that applies to the ISAM hardware appliance only)
- **Terraform variable:** `var.ivia_activation_code` (sensitive = true)
- **HCP Terraform:** Set as a sensitive workspace variable — never commit in `terraform.tfvars`
- **How used:** The autoconf Job sets `IVIA_BASE_CODE`, `IVIA_AAC_CODE`, and `IVIA_FED_CODE` env vars all to this value

## CIBA Consent Flow

```
1. Use Case 3 agent -> POST /oauth2/ciba (direct to OIDC Provider ClusterIP)
   OIDC Provider returns auth_req_id

2. OIDC Provider executes notifyuser mapping rule:
   ciba.setAuthenticator(new InternalAuthenticator())
   -> OIDC Provider tells WRP to serve consent at:
      http://<wrp-alb>/isvaop/oauth2/ciba_user_authorize/{auth_req_id}

3. Agent displays consent URL in chat -> user opens URL in browser -> hits WRP ALB
   WRP enforces anyauth ACL (requires authenticated session)
   WRP shows login page (username/password)
   WRP validates credentials via AAC Runtime -> Simple AD LDAP

4. User authenticates -> WRP forwards authenticated session to OIDC Provider
   OIDC Provider renders ciba_user_authorize_success.html
   User approves consent

5. Use Case 3 agent polls POST /oauth2/token (direct to OIDC Provider ClusterIP)
   OIDC Provider returns access_token (CIBA approved)
```

## Prerequisites

1. **IBM entitlement key** — Required for the ICR pull secret (Pitfall 3). Without this, all four pods enter `ImagePullBackOff`. Set `icr_entitlement_key` as a sensitive workspace variable in HCP Terraform.

2. **IBM activation code** — Required for Config container module activation. See Activation Codes section above.

3. **AWS Load Balancer Controller** — Must be deployed (`module.addons`) before this module for the WRP ALB Ingress to be provisioned.

4. **Vault endpoint** — `module.vault.vault_endpoint` must exist before IVIA deploys, as it is referenced in the OIDC Provider configuration.

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
| `icr_entitlement_key` | `string` | yes | IBM Container Registry entitlement key for image pull auth (all four containers). |
| `ivia_activation_code` | `string` | yes | IBM activation code (M11DCML) for webseal + aac + federation modules. |
| `tags` | `map(string)` | no | Tags applied to all AWS resources. Default: `{}`. |

## Outputs

| Name | Description |
|------|-------------|
| `ivia_oidc_discovery_url` | Internal OIDC discovery URL (ClusterIP path). Vault jwt auth method consumes this. Format: `https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration` |
| `ivia_namespace` | Kubernetes namespace (`verify-access`). |
| `ivia_service_endpoint` | ClusterIP service DNS without scheme. Format: `isvaop.verify-access.svc.cluster.local` |
| `ivia_wrp_hostname` | WRP ALB hostname from LBC. The external entry point for browser flows. May be empty until LBC reconciles the Ingress. |
| `ivia_ingress_hostname` | Legacy output alias for `ivia_wrp_hostname`. |

## Root Module Wiring

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
  ivia_activation_code       = var.ivia_activation_code
  tags                       = var.tags
}
```

## Post-Deploy Verification

```bash
# Check all four IVIA pods are running
kubectl get pods -n verify-access

# Expected: ivia-config, ivia-runtime, ivia-wrp, isvaop all Running

# Check WRP ALB Ingress (may take 2-3 minutes for LBC to provision)
kubectl get ingress -n verify-access

# Verify OIDC discovery via WRP junction (external path)
WRP_HOST=$(kubectl get ingress -n verify-access ivia-wrp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$WRP_HOST/isvaop/oauth2/.well-known/openid-configuration" | jq .issuer

# Verify OIDC discovery via ClusterIP (in-cluster path used by Vault jwt auth)
kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never \
  -n verify-access -- \
  curl -sk https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration \
  | jq '{issuer, grant_types_supported, backchannel_authentication_endpoint}'
```

The discovery response must contain `"issuer"`, `"grant_types_supported"`, and `"backchannel_authentication_endpoint"` fields.

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

**Pitfall 1 — Config must start before Runtime and WRP.** If `ivia-runtime` or `ivia-wrp` pods crash with `CrashLoopBackOff`, check whether `ivia-config` is Running first. Runtime and WRP download their configuration snapshot from Config's LMI on startup — if Config is not ready, they cannot start. The `depends_on` ordering in this module enforces the sequence.

**Pitfall 2 — Activation codes are mandatory.** Without a valid activation code, the autoconf Job cannot enable the webseal, aac, or federation modules. The WRP and AAC Runtime will start but will not be properly configured. Obtain `M11DCML` from IBM Passport Advantage — the trial `.cer` file is for the ISAM hardware appliance only.

**Pitfall 3 — cfgsvc password mismatch.** The Config container sets a random `cfgsvc` service account password at first boot. The autoconf Job and all workers must use the same password. This module manages password consistency via a Kubernetes Secret — do not manually change the cfgsvc password in the LMI UI.

**Pitfall 4 — ICR pull secret missing.** All four IVIA images are hosted at `icr.io/ivia/`. Without the `icr-pull-secret` Kubernetes secret, all pods enter `ImagePullBackOff`. This module creates the secret using `var.icr_entitlement_key` — the secret must be created before any Deployment reconciles. The `depends_on` block ensures ordering.

**Pitfall 5 — Use `kubernetes_*` resources, not `kubectl_manifest`.** The `kubernetes` provider (hashicorp/kubernetes ~> 2.25) is already declared in `providers.tf`. Adding a separate `gavinbunney/kubectl` provider would introduce an extra provider dependency. All manifests in this module use `kubernetes_namespace`, `kubernetes_deployment`, `kubernetes_service`, `kubernetes_ingress_v1`, etc.

**Pitfall 6 — RDS output names have no `rds_` prefix.** The RDS module outputs are `endpoint`, `address`, `port`, `master_username`, `master_user_secret_arn`, `db_name` — NOT `rds_endpoint`, `rds_address`, etc. Use `module.rds.endpoint` (not `module.rds.rds_endpoint`) when wiring the ivia module in `main.tf`.
