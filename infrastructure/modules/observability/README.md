# observability

Three-plane audit correlation infrastructure for the Agentic Runtime Security Workshop (Phase 6 — Use Case 3).

## Architecture

```
Kubernetes Pods                 CloudWatch               Firehose           S3
─────────────────────           ────────────────────     ────────────────   ───────────────────────
vault-* containers    ──────▶  /workshop/vault-audit   ─────────────────▶  vault-audit/
isvaop-* containers   ──────▶  /workshop/ivia-decision ─────────────────▶  ivia-decision/
uc3-agent-* containers ─────▶  /workshop/agent-trace   ─────────────────▶  agent-trace/
```

fluent-bit runs as a DaemonSet on every EKS node, tails `/var/log/containers/*.log`, and routes structured JSON to the three pre-created `/workshop/*` CloudWatch log groups (owned by the `audit` module). CloudWatch subscription filters forward each log group to a dedicated Kinesis Data Firehose delivery stream. Each stream delivers to an S3 prefix with date-partitioned keys.

Glue catalog tables layer an external schema over the S3 prefixes, enabling Athena SQL. The `audit_correlation` VIEW (created via the stored named query) joins all four log planes on the W3C `traceparent` `request_id`.

## Components

| Resource | Type | Purpose |
|---|---|---|
| `helm_release.fluent_bit` | Helm (aws-for-fluent-bit) | Routes pod logs to CloudWatch |
| `aws_eks_pod_identity_association.fluent_bit` | Pod Identity | CloudWatch write permissions for fluent-bit SA |
| `aws_s3_bucket.logs` | S3 | Log export destination with 30-day lifecycle |
| `aws_kinesis_firehose_delivery_stream.*` | Firehose (×3) | Near-real-time delivery to S3 |
| `aws_cloudwatch_log_subscription_filter.*` | CW Subscription (×3) | Fan-out: log group → Firehose |
| `aws_glue_catalog_table.*` | Glue (×4) | Schema for vault_audit, ivia_decisions, agent_traces, cloudtrail_events |
| `aws_athena_named_query.audit_correlation_view` | Athena | CREATE OR REPLACE VIEW DDL for attendees |

## Design Decisions

- **auto_create_group = false** in fluent-bit config — log group lifecycle is owned by the `audit` module (prevents orphan resources on destroy).
- **Pod Identity over IRSA** — consistent with workshop EKS identity pattern (Phase 2 managed addons, Phase 3 Vault).
- **Athena VIEW as named query** — avoids `null_resource`/`local-exec` dependency on Athena at apply time; attendees execute it as a lab step.
- **30-day S3 lifecycle** — workshop ephemeral cost control; Firehose buffering set to 60s/5MB for near-real-time availability.
- **JSON SerDe with `ignore.malformed.json = TRUE`** — tolerates startup noise and partial log lines without breaking Athena queries.

## Inputs

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | string | — | AWS region (interpolated; never hardcoded) |
| `cluster_name` | string | — | EKS cluster name for Pod Identity + resource naming |
| `namespace` | string | `"logging"` | Kubernetes namespace for fluent-bit DaemonSet |
| `log_bucket_name` | string | — | S3 bucket name for Firehose log export |
| `glue_database_name` | string | `"workshop_logs"` | Existing Glue DB (audit module) |
| `athena_workgroup` | string | `"workshop"` | Existing Athena workgroup (audit module) |
| `kms_key_arn` | string | — | Workshop CMK ARN for S3 SSE |
| `tags` | map(string) | `{}` | Tags for all resources |

## Outputs

| Output | Description |
|---|---|
| `log_bucket_name` | S3 bucket name for log exports |
| `log_bucket_arn` | S3 bucket ARN |
| `fluent_bit_namespace` | Namespace where fluent-bit runs |
| `athena_correlation_query` | SELECT query for `audit_correlation` view (use in verify-uc3.sh) |
| `athena_view_named_query_id` | Athena named query ID — retrieve DDL via AWS CLI |
| `firehose_stream_arns` | Map of log source → Firehose stream ARN |

## Verification

```bash
# fluent-bit DaemonSet running on all nodes
kubectl get ds -n logging aws-for-fluent-bit

# Firehose delivery streams active
aws firehose list-delivery-streams --query 'DeliveryStreamNames'

# Glue tables in workshop_logs database
aws glue get-tables --database-name workshop_logs --query 'TableList[].Name'

# Athena named query ID (run the CREATE VIEW DDL)
terraform -chdir=infrastructure output -raw observability_athena_view_named_query_id
aws athena get-named-query --named-query-id <id>
```
