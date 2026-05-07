# Audit Module

The load-bearing audit foundation for the Agentic Runtime Security workshop. Establishes the cross-plane audit-correlation contract before any other AWS resource is created.

## Purpose

Per `.planning/phases/02-foundation-infrastructure/02-CONTEXT.md`: traceability and auditability are THE workshop's load-bearing concern — the audit-correlation contract is the artifact every Phase 3-6 deliverable consumes. This module ships the workshop's CMK, the three pre-created CloudWatch log groups, and the Glue + Athena scaffold that the cross-plane query template runs against.

## Resources

| Resource | Identifier | Purpose |
|----------|-----------|---------|
| `aws_kms_key.workshop` (+ alias `alias/workshop-data`) | Workshop CMK | RDS storage / AOSS encryption / S3 corpus SSE / CloudWatch log group encryption (Pattern 6: one CMK reused) |
| `aws_cloudwatch_log_group.workshop_audit` (×3) | `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace` | Per-source audit log groups (Pattern 7: per-source, KMS-encrypted) |
| `aws_glue_catalog_database.workshop_logs` | `workshop_logs` | Schema registry for cross-plane Athena queries (empty in Phase 2; Phase 6 adds tables) |
| `aws_athena_workgroup.workshop` | `workshop` | Default Athena workgroup with KMS-encrypted query results |
| `aws_s3_bucket.athena_results` | `workshop-athena-<random>` | Query result bucket (workshop CMK SSE) |

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `region` | string | (required) | AWS region; interpolated into the CloudWatch Logs service principal |
| `audit_retention_days` | number | `7` | CloudWatch log group retention (days) |
| `tags` | map(string) | `{}` | Tags applied to all resources |

## Outputs

| Name | Type | Description |
|------|------|-------------|
| `workshop_cmk_arn` | string | Reused by RDS, AOSS, S3 SSE consumers |
| `workshop_cmk_id` | string | Key ID |
| `workshop_cmk_alias` | string | `alias/workshop-data` |
| `audit_log_groups` | map(string) | Audit source → log group ARN |
| `audit_log_group_names` | map(string) | Audit source → log group name |
| `glue_database_name` | string | `workshop_logs` |
| `athena_workgroup_name` | string | `workshop` |
| `athena_results_bucket` | string | S3 bucket holding query results |

## Downstream Consumption

- **Phase 3 (Vault + IVIA + agents)** — fluent-bit configs ship logs into the three pre-created log groups by ARN (`audit_log_groups` output).
- **Phase 5 (UC1-3 agents)** — emit OpenTelemetry traces with W3C `traceparent` header into `/workshop/agent-trace`.
- **Phase 6 (UC3 + observability)** — populates Glue tables in `workshop_logs` and runs the cross-plane Athena query in workgroup `workshop`.

## See Also

- [`infrastructure/docs/audit-correlation-queries.md`](../../docs/audit-correlation-queries.md) — the W3C `traceparent` contract + composite-key Athena join template that this module's resources back.
- `.planning/phases/02-foundation-infrastructure/02-RESEARCH.md` — Patterns 6-7, Workshop CMK key policy snippet, Pitfall T1 (no hardcoded region).
