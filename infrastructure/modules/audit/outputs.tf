################################################################################
# Audit Module — Outputs
# Consumed by every downstream Phase 2+ component that emits or queries logs.
################################################################################

output "workshop_cmk_arn" {
  description = "Workshop CMK ARN. Reused by RDS storage encryption, AOSS encryption policy, S3 corpus SSE, and any future CMK consumer."
  value       = aws_kms_key.workshop.arn
}

output "workshop_cmk_id" {
  description = "Workshop CMK key ID."
  value       = aws_kms_key.workshop.key_id
}

output "workshop_cmk_alias" {
  description = "Workshop CMK alias (alias/workshop-data)."
  value       = aws_kms_alias.workshop.name
}

output "audit_log_groups" {
  description = "Map of audit-source name → CloudWatch log group ARN. Keys: vault-audit, ivia-decision, agent-trace. Phase 3 fluent-bit configs reference these by ARN."
  value       = { for k, lg in aws_cloudwatch_log_group.workshop_audit : k => lg.arn }
}

output "audit_log_group_names" {
  description = "Map of audit-source name → CloudWatch log group name (/workshop/<source>). Phase 3 fluent-bit + Phase 6 Glue tables read these."
  value       = { for k, lg in aws_cloudwatch_log_group.workshop_audit : k => lg.name }
}

output "glue_database_name" {
  description = "Glue catalog database name (workshop_logs). Phase 6 adds tables for cross-plane Athena queries."
  value       = aws_glue_catalog_database.workshop_logs.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup name (workshop). Default workgroup for the cross-plane audit-correlation queries documented in infrastructure/docs/audit-correlation-queries.md."
  value       = aws_athena_workgroup.workshop.name
}

output "athena_results_bucket" {
  description = "S3 bucket holding Athena query results (workshop CMK SSE)."
  value       = aws_s3_bucket.athena_results.id
}
