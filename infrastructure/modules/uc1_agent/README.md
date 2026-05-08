# uc1_agent Module

Terraform module that provisions all Kubernetes resources for the **Use Case 1 non-personalized read-only Strands agent**. The agent authenticates to Vault using its ServiceAccount JWT (Kubernetes auth backend), obtains JIT database credentials (uc1-readonly role, 15-minute TTL) and Vault-vended Bedrock STS credentials (bedrock-reader role), then performs read-only product catalog retrieval via Amazon Bedrock Knowledge Base.

## Resources Created

| Resource | Kind | Name |
|---|---|---|
| `kubernetes_namespace.uc1` | Namespace | `uc1` |
| `kubernetes_service_account.uc1` | ServiceAccount | `uc1-retriever-sa` |
| `kubernetes_config_map.uc1_config` | ConfigMap | `uc1-config` |
| `kubernetes_deployment.uc1` | Deployment | `uc1-agent` |
| `kubernetes_service.uc1` | Service | `uc1-agent-svc` |
| `kubernetes_network_policy.uc1_egress` | NetworkPolicy | `uc1-egress` |

## Vault Dependency

This module assumes `vault_config` has already applied the following:

- **Policy** `uc1-readonly` — allows `database/creds/uc1-readonly` (read) and `aws/sts/bedrock-reader` (read, update).
- **Kubernetes auth role** `uc1` — `bound_service_account_names = ["uc1-retriever-sa"]`, `bound_service_account_namespaces = ["uc1"]`.

The `uc1-retriever-sa` ServiceAccount name must match exactly between this module and `vault_config`. If you change one, change the other.

## NetworkPolicy — Egress Rules (ENFC-01)

All outbound traffic from pods in the `uc1` namespace is denied by default except:

| Port | Protocol | Destination |
|---|---|---|
| 53 | UDP | CoreDNS (kube-dns) |
| 8200 | TCP | Vault cluster-internal API (`vault.vault.svc`) |
| 5432 | TCP | RDS PostgreSQL (Vault-vended ephemeral credentials) |
| 443 | TCP | Bedrock InvokeModel + KB Retrieve, STS AssumeRole (VPC endpoints + NAT GW for cross-region KB) |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `vault_addr` | string | `http://vault.vault.svc.cluster.local:8200` | Vault cluster-internal address |
| `vault_role` | string | `uc1` | Vault Kubernetes auth role name |
| `rds_address` | string | — | RDS endpoint host (no port) |
| `rds_port` | number | `5432` | RDS TCP port |
| `rds_db_name` | string | `workshop` | PostgreSQL database name |
| `knowledge_base_id` | string | — | Bedrock Knowledge Base ID |
| `region` | string | — | Primary AWS region (EKS + Vault) |
| `kb_region` | string | — | KB AWS region (must match the embedding model region) |
| `agent_image` | string | — | Container image URI (ECR repo + tag) |
| `bedrock_model_id` | string | `us.amazon.nova-pro-v1:0` | Bedrock inference profile ID |
| `tags` | map(string) | `{}` | Informational tags (not applied to Kubernetes resources) |

## Outputs

| Name | Description |
|---|---|
| `agent_namespace` | Kubernetes namespace name (`uc1`) |
| `agent_service_name` | Service name (`uc1-agent-svc`) |
| `agent_deployment_name` | Deployment name (`uc1-agent`) |
| `agent_service_account_name` | ServiceAccount name (`uc1-retriever-sa`) |

## Agent Application Code

The UC1 Strands agent Python application lives in `infrastructure/modules/uc1_agent/agent/` (populated in Plan 04-02). The `agent_image` input receives the ECR URI built from that source tree.

## Region Contract

No hardcoded region string literals appear in any `.tf` file in this module. All region values flow through `var.region` (primary cluster region) and `var.kb_region` (Knowledge Base region).

## Required Providers

| Provider | Source | Version |
|---|---|---|
| kubernetes | hashicorp/kubernetes | ~> 2.25 |
