# uc3_agent

Terraform module that deploys the **UC3 CIBA-privileged action agent** into the `banking-app` namespace on the workshop EKS cluster.

## What this module provisions

| # | Resource | Name | Purpose |
|---|----------|------|---------|
| 1 | `kubernetes_service_account` | `uc3-privileged-actor-sa` | Vault k8s auth subject — the agent logs in with its projected SA JWT (role `uc3`, policy `uc3-agent`: read-only DB creds, Bedrock and CloudWatch Logs STS). This login cannot reach `uc3-refund-writer` |
| 2 | `kubernetes_config_map` | `uc3-agent-config` | Runtime env vars (Vault, IVIA, DB, Bedrock) |
| 3 | `kubernetes_deployment` | `uc3-agent` | Single-replica FastAPI agent on port 8080 |
| 4 | `kubernetes_service` | `uc3-agent-svc` | ClusterIP 8080 → 8080 — no ALB/Ingress |
| 5 | `kubernetes_network_policy` | `uc3-default-deny` | Zero-trust baseline — blocks all ingress/egress for uc3-agent pods |
| 6 | `kubernetes_network_policy` | `uc3-allow-dns` | CoreDNS egress (UDP/TCP 53) |
| 7 | `kubernetes_network_policy` | `uc3-allow-vault` | Vault API egress (TCP 8200) |
| 8 | `kubernetes_network_policy` | `uc3-allow-rds` | RDS egress (TCP 5432) scoped to `var.rds_cidr` |
| 9 | `kubernetes_network_policy` | `uc3-allow-ivia` | IVIA CIBA polling egress (TCP 443 + 9443) |
| 10 | `kubernetes_network_policy` | `uc3-allow-bedrock` | Bedrock VPC endpoint egress (TCP 443, 0.0.0.0/0) |
| 11 | `kubernetes_network_policy` | `uc3-allow-inbound` | Ingress from banking-agent (label `app=uc2-agent`) on TCP 8080 |

## Security design

- **OBJ-1 Workload identity**: `uc3-privileged-actor-sa` is the Vault Kubernetes auth role subject. No static credentials.
- **OBJ-2 No standing privileges**: The agent's own login (role `uc3`) is bound to the `uc3-agent` policy (its tokens also carry Vault's built-in `default`), and neither has a refund-writer path. For each approved refund the agent presents that refund's delegated token and receives a fresh short-TTL `uc3-refund-writer` database credential, which expires after the TTL configured in `vault_config`. `verify-uc3.sh` Check 21, in both normal mode and `--bypass`, asserts that the `uc3` login is denied the refund writer.
- **OBJ-3 User intent enforcement**: Vault's native OAuth resource server resolves the agent from the token's `act.sub` against the Agent Registry (applying the `uc3-agent-ceiling`) and enforces the per-request `vault:path_access` RAR before issuing DB credentials — the `may_act` claim IVIA also stamps is ignored by native OBO.
- **OBJ-5 Audit correlation**: the CIBA `request_id` (the approval's `binding_message`) is threaded into the DB write as a `uc3_request_id` SQL comment that pgaudit captures verbatim; the `audit_correlation` Athena VIEW joins IVIA↔pgaudit on `request_id` and bridges the Vault audit plane by credential path + time-proximity (native Vault audit logs neither `request_id` nor the human sub).
- **No Ingress / ALB**: The UC3 agent is reached in-cluster from `banking-agent-svc` or via `kubectl port-forward` for workshop demos.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `namespace` | `string` | `"banking-app"` | Kubernetes namespace for all resources |
| `vault_endpoint` | `string` | — | Vault cluster-internal URL (e.g. `http://vault.vault.svc.cluster.local:8200`) |
| `vault_role` | `string` | `"uc3"` | Vault Kubernetes auth role name |
| `ivia_base_url` | `string` | — | IVIA service base URL for CIBA token polling |
| `ivia_client_id` | `string` | `"agent-uc3"` | IVIA OAuth client ID for the UC3 agent |
| `ivia_client_secret` | `string` | — | IVIA OAuth client secret (sensitive) |
| `db_host` | `string` | — | PostgreSQL host (RDS endpoint, no port) |
| `db_port` | `number` | `5432` | PostgreSQL TCP port |
| `db_name` | `string` | `"workshop"` | PostgreSQL database name |
| `uc3_agent_image` | `string` | — | ECR image URI for the UC3 agent container |
| `bedrock_model_id` | `string` | `"us.amazon.nova-pro-v1:0"` | Bedrock inference profile ID |
| `region` | `string` | — | AWS region where the EKS cluster runs |
| `rds_cidr` | `string` | — | VPC CIDR covering the RDS subnet group |
| `vault_cidr` | `string` | `""` | Optional Vault pod CIDR for tighter NetworkPolicy |
| `tags` | `map(string)` | `{}` | Informational AWS tags |

## Outputs

| Name | Description |
|------|-------------|
| `service_name` | Kubernetes Service name (`uc3-agent-svc`) |
| `service_account_name` | ServiceAccount name (`uc3-privileged-actor-sa`) |
