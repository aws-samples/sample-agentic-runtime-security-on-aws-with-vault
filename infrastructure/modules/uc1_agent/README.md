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

Strands is pinned to `strands-agents==1.57.0` and `strands-agents-tools==0.8.9` in `agent/requirements.txt`.

### `POST /query`

Body: `{"query": "<question>"}`. The `Accept` header picks the reply format.

**Default — JSON.** Any request that does not ask for `text/event-stream` (curl's default `*/*`, no `Accept` header at all, `application/json`) gets:

```json
{
  "answer": "…",
  "sources": ["# Employee Handbook This handbook describes the working norms …", "…"],
  "credential_metadata": {
    "vault_authenticated": true,
    "vault_role": "uc1",
    "leases": [{ "vault_path": "database/creds/uc1-readonly", "lease_id": "database/creds/uc1-readonly/…", "ttl_seconds": 900 }]
  }
}
```

`sources` holds the Knowledge Base passages the agent read for this answer, in the order it retrieved them, and is `[]` when it did not search the Knowledge Base. `leases` lists every database credential Vault issued for this request, with the lease id spelled exactly as the Vault audit log spells it. It is `[]` when the question was answered from the Knowledge Base alone. The "Verify Credentials and Enforcement" page and check 9 of `verify-uc1.sh` read this reply.

**`Accept: text/event-stream` — each step as it happens.** Server-Sent Events, one `data: <json>` frame per event, in the contract of `applications/banking-app/ui/src/lib/agent-events.ts`:

| Event | What it says |
|---|---|
| `tool_planning` (legacy) | "Processing your request..." — always first |
| `agent:thinking` | the agent starts reasoning |
| `agent:narration` | no user is signed in; the agent either signs in to Vault as itself (Kubernetes auth, with the service account and Vault role Vault reports) or reuses its current login; then it reuses (or refreshes) its AWS keys for calling the model |
| `tool_call` | each tool call, `in_progress` then `success` or `error`, with `args`, `result` and `durationMs`. A `retrieve_from_knowledge_base` result carries `sources`: `document` (S3 URI), `score`, `text`. A `query_database` result carries `row_count` (every row) and the first `rows`, up to 50 and up to 256 KiB of JSON, so the frame stays under the UI filter's 1 MiB limit, when the rows are JSON; rows with values JSON cannot hold (dates, decimals) arrive as text in `output` |
| `agent:narration` | during a tool call: Vault issued short-lived AWS credentials for the Knowledge Base (`aws/sts/bedrock-reader`, TTL), or a database credential (`database/creds/uc1-readonly`, lease id, TTL); at any point: Vault issued fresh keys for calling the model |
| `agent:credential` | each credential the turn used, in full (see below) |
| `agent:audit_seed` | `requestId`, `vaultRole`, `leases` — the same leases as the JSON reply |
| `agent:narration` | the `credential_metadata` the JSON reply would carry, then "Writing the answer." |
| `agent:text_delta` + `delta` (legacy) | the answer, whole |
| `end` (legacy), then `agent:done` | the turn is over; nothing follows `agent:done` |

Tool, narration and credential events arrive in the order they happen. On failure the stream ends `agent:error` → `error` (legacy) → `end` → `agent:done`. Every current event carries `requestId` (a UUID per turn, also written to the agent's `query_received` / `query_complete` log lines) and `ts` (epoch milliseconds). A client that disconnects stops the agent at its next checkpoint.

`agent:credential` events show the credentials in full, for the workshop's live view of what happens behind each answer. Every one carries `reused` (a boolean): `true` when the credential was obtained before this turn and is used again now, `false` when it was made or first presented during the turn. The Agent Log reads this flag, not the label, to print "reused", "presented" or "issued".

| `kind` | Credential | When | `reused` |
|---|---|---|---|
| `k8s_sa_token` | the service-account JWT the agent presented to Vault, with its decoded (unverified) `claims` | each turn whose Vault login check succeeds, and again whenever the agent signs in mid-turn | `true` when the turn reuses an earlier login, `false` when the agent signs in during the turn |
| `vault_token` | the Vault token that login returned, with `ttlSeconds` | with each `k8s_sa_token` | the same as that `k8s_sa_token` |
| `aws_sts_credentials` | `fields.access_key_id`, `secret_access_key`, `session_token` from `aws/sts/bedrock-reader` | each Knowledge Base call | `false` |
| `aws_sts_credentials` | the model's own keys from the same path, read live from the credentials the model signs with; the label says they are for calling the model | every streamed turn: at the start of the turn, or when botocore refreshes them during this answer (within 15 minutes of expiry, at the turn's first read of them or on the Bedrock call that needs them) | `true` at the start of the turn, `false` when refreshed during this answer |
| `db_credentials` | `fields.username`, `password` from `database/creds/uc1-readonly`, with `leaseId` | each `query_database` call | `false` |

These values go only onto the requesting visitor's stream. They are never written to the pod log, never returned from a tool (tool results go to Bedrock), and never added to the JSON reply. The knowledge-base keys and the database login are issued per request. The model's keys are shared by every request, so every visitor sees the same ones until they are refreshed; the refresh appears on the stream of the turn that triggered it. The service-account JWT and the Vault token are the agent's own login, so every visitor sees the same ones until the agent signs in again.

**Concurrency.** The Vault login and the Bedrock model are set up once at pod startup. Each `/query` builds its own Strands `Agent` and runs it in a worker thread, so visitors are answered in parallel and no visitor's question or answer enters another visitor's conversation.

## Region Contract

No hardcoded region string literals appear in any `.tf` file in this module. All region values flow through `var.region` (primary cluster region) and `var.kb_region` (Knowledge Base region).

## Required Providers

| Provider | Source | Version |
|---|---|---|
| kubernetes | hashicorp/kubernetes | ~> 2.25 |
