# uc3_agent

Terraform module that deploys the **UC3 CIBA-privileged action agent** into the `banking-app` namespace on the workshop EKS cluster.

## What this module provisions

| # | Resource | Name | Purpose |
|---|----------|------|---------|
| 1 | `kubernetes_service_account` | `uc3-privileged-actor-sa` | Vault k8s auth subject — agent mounts projected SA JWT and exchanges it for a short-TTL `uc3-refund-writer` token |
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
- **OBJ-2 No standing privileges**: The agent fetches a short-TTL `uc3-refund-writer` Vault token per privileged action; the token expires after the TTL configured in `vault_config`.
- **OBJ-3 User intent enforcement**: Vault JWT policy validates `may_act` and RAR claims on the IVIA CIBA actor token before issuing DB credentials.
- **OBJ-5 Audit correlation**: W3C `traceparent` propagated in every Vault and IVIA call; pgaudit captures the resulting SQL write with the same trace ID.
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
