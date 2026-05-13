################################################################################
# Observability Module — Outputs
# Consumed by verify-uc3.sh and workshop walkthrough content.
################################################################################

output "log_bucket_name" {
  description = "S3 bucket name receiving log exports from Kinesis Firehose streams (vault-audit, ivia-decision, agent-trace prefixes)."
  value       = aws_s3_bucket.logs.id
}

output "log_bucket_arn" {
  description = "S3 bucket ARN for the log export bucket."
  value       = aws_s3_bucket.logs.arn
}

output "fluent_bit_namespace" {
  description = "Kubernetes namespace where the fluent-bit DaemonSet runs."
  value       = var.namespace
}

output "athena_correlation_query" {
  description = "SELECT query for cross-plane audit correlation. Execute after running the create-audit-correlation-view named query to create the VIEW, then run this to query it."
  value       = local.athena_select_sql
}

output "athena_view_named_query_id" {
  description = "Athena named query ID for the CREATE OR REPLACE VIEW audit_correlation DDL. Retrieve with: aws athena get-named-query --named-query-id <id>"
  value       = aws_athena_named_query.audit_correlation_view.id
}

output "firehose_stream_arns" {
  description = "Map of log source name → Kinesis Firehose delivery stream ARN."
  value = {
    vault_audit   = aws_kinesis_firehose_delivery_stream.vault_audit.arn
    ivia_decision = aws_kinesis_firehose_delivery_stream.ivia_decision.arn
    agent_trace   = aws_kinesis_firehose_delivery_stream.agent_trace.arn
  }
}
