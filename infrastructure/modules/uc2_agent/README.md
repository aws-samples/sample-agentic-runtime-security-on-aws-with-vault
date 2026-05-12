# uc2_agent — UC2 OAuth-Personalized Banking App Module

Deploys the UC2 banking app workload into the `banking-app` Kubernetes namespace:
three services (SvelteKit UI, Python Strands agent, Node.js MCP server), dedicated
ServiceAccounts, default-deny + per-pod NetworkPolicies (ENFC-03), an ALB Ingress
for the UI, ConfigMaps, and a DB schema seed provisioner.

## Architecture

```
Internet
   │  HTTP:80
   ▼
ALB Ingress (internet-facing)
   │  :5173
   ▼
banking-ui (SvelteKit PKCE)          uc2-ui-sa
   │  :3002
   ▼
banking-agent (Python Strands)       uc2-agent-sa  ←→  Vault k8s auth (startup)
   │  :3001                                              AWS Bedrock InvokeModel
   ▼
banking-mcp-server (Node.js MCP)     uc2-mcp-server-sa ←→ Vault JWT auth (per request)
   │                                                        → Vault DB creds (uc2-personal-readonly)
   ▼                                                        → SET app.current_user_sub
PostgreSQL RDS (banking schema, RLS)
```

### Service Accounts

| ServiceAccount | Namespace | Vault Binding | Purpose |
|---|---|---|---|
| `uc2-ui-sa` | `banking-app` | None | SvelteKit UI — no Vault access |
| `uc2-agent-sa` | `banking-app` | k8s auth role `uc2` at startup | Strands agent workload identity |
| `uc2-mcp-server-sa` | `banking-app` | k8s auth role `uc2` (bound SA) | Issues per-user JWT auth to Vault for DB cred vending |

Only `uc2-mcp-server-sa` is bound to the Vault `uc2` Kubernetes auth role
(`vault_config` module). The MCP server authenticates to Vault *per user request*
using the user's IVIA JWT (`uc2-jwt` role), then fetches `uc2-personal-readonly`
ephemeral credentials. The agent forwards the user's JWT to the MCP server and
never touches DB credentials directly.

## NetworkPolicy Design

### Zero-Trust Baseline (ENFC-03)

A `default-deny-all` NetworkPolicy blocks all ingress and egress for every pod in
`banking-app` before any per-pod policies apply. A namespace-wide `allow-dns`
policy then opens 53/UDP and 53/TCP to CoreDNS for all pods.

### Per-Pod Policies

| Pod | Ingress Allowed | Egress Allowed |
|---|---|---|
| `banking-ui` | 0.0.0.0/0 :5173 (ALB health + user) | `banking-agent`:3002, :443 (IVIA OIDC) |
| `banking-agent` | `banking-ui`:3002 | `banking-mcp-server`:3001, :8200 (Vault), :443 (Bedrock) |
| `banking-mcp-server` | `banking-agent`:3001 | :8200 (Vault), `rds_cidr`:5432 (RDS), :443 (IVIA) |

RDS egress uses a CIDR block (`var.rds_cidr`) because RDS is an AWS-managed resource
outside the Kubernetes pod network. Vault and Bedrock egress use port-only rules
because they resolve via in-cluster DNS (Vault) and VPC interface endpoints (Bedrock).

## ALB Ingress

| Annotation | Value |
|---|---|
| `alb.ingress.kubernetes.io/scheme` | `internet-facing` |
| `alb.ingress.kubernetes.io/target-type` | `ip` (direct pod IP routing) |
| `alb.ingress.kubernetes.io/listen-ports` | `[{"HTTP":80}]` (HTTP-only) |
| `kubernetes.io/ingress.class` | `alb` |

HTTP-only is intentional for the workshop — this simplifies the PKCE redirect URI
configuration (`http://<alb-hostname>/callback`) and avoids certificate provisioning
overhead. The `banking_ui_alb_hostname` output provides the hostname for IVIA
redirect URI configuration (see `ivia-configure.sh`).

## DB Seed

Database seeding runs post-deploy via `seed-banking-db.sh`. The script retrieves master
credentials from Secrets Manager, creates a ConfigMap from `seed.sql`, and
runs a disposable `postgres:16-alpine` pod to execute psql against RDS.
`seed.sql` is idempotent (`IF NOT EXISTS` + `ON CONFLICT DO NOTHING`).
`configure-workshop.sh` calls this script automatically after each workspace apply.

## Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `vault_addr` | string | `http://vault.vault.svc.cluster.local:8200` | Vault cluster-internal address |
| `vault_k8s_role` | string | `uc2` | Vault Kubernetes auth role for MCP server SA |
| `vault_jwt_role` | string | `uc2-jwt` | Vault JWT auth role for per-user token exchange |
| `vault_db_role` | string | `uc2-personal-readonly` | Vault DB role for SELECT-only ephemeral creds |
| `rds_address` | string | — | RDS endpoint host (no port) |
| `rds_port` | number | `5432` | RDS TCP port |
| `rds_db_name` | string | `workshop` | PostgreSQL database name |
| `rds_endpoint` | string | — | RDS host:port for DB seed psql |
| `rds_master_user_secret_arn` | string | — | Secrets Manager ARN for master DB credentials |
| `rds_cidr` | string | — | VPC subnet CIDR for RDS NetworkPolicy egress |
| `knowledge_base_id` | string | — | Bedrock KB ID used by the agent |
| `region` | string | — | Primary AWS region (EKS + Vault) |
| `kb_region` | string | — | AWS region for Bedrock Knowledge Base |
| `ui_image` | string | — | SvelteKit UI container image URI |
| `agent_image` | string | — | Python Strands agent container image URI |
| `mcp_image` | string | — | Node.js MCP server container image URI |
| `bedrock_model_id` | string | `us.amazon.nova-pro-v1:0` | Bedrock CRIS inference profile ID |
| `ivia_issuer` | string | — | IVIA OIDC issuer URL |
| `ivia_client_id` | string | `agent-uc2` | IVIA OAuth client ID |
| `tags` | map(string) | `{}` | Resource tags (informational) |

## Outputs

| Output | Description |
|---|---|
| `namespace` | Kubernetes namespace (`banking-app`) |
| `banking_ui_alb_hostname` | ALB hostname for the banking UI Ingress |
| `banking_ui_service_name` | ClusterIP Service name for banking UI |
| `banking_agent_service_name` | ClusterIP Service name for Strands agent |
| `mcp_server_service_name` | ClusterIP Service name for MCP server |
| `mcp_server_service_account_name` | SA name bound to Vault uc2 k8s auth role |

## Root module wiring

This module is called as `module.uc2_app` in `infrastructure/main.tf`. It depends on:

- `module.vault` → `vault_endpoint` (Vault addr)
- `module.vault_config` → `uc2_role_name`, `uc2_db_role_name`
- `module.eks` → cluster providers (via root `providers.tf` chicken-and-egg pattern)
- `module.rds` → `db_address`, `db_master_user_secret_arn`
- `module.bedrock_kb_index` → `knowledge_base_id`

Attendee-supplied values (`ui_image`, `agent_image`, `mcp_image`) are set in
`terraform.tfvars` after running `build-banking-app.sh`.
