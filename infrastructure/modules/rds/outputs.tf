################################################################################
# RDS Module — Outputs
# Consumed by component.vault (Phase 3) and the UC1/UC2/UC3 agents (Phase 4-6).
################################################################################

output "endpoint" {
  description = "RDS connection endpoint in <address>:<port> form. Vault PostgreSQL secrets engine and the agents connect here."
  value       = aws_db_instance.pg17.endpoint
}

output "address" {
  description = "RDS hostname (without port) — useful when callers need the bare DNS name."
  value       = aws_db_instance.pg17.address
}

output "port" {
  description = "RDS listening port (5432)."
  value       = aws_db_instance.pg17.port
}

output "db_instance_id" {
  description = "RDS instance identifier — referenced by Phase 6 audit-correlation queries against /aws/rds/instance/<id>/postgresql."
  value       = aws_db_instance.pg17.id
}

output "db_security_group_id" {
  description = "RDS security group ID — Phase 3 Vault Helm values consume this only if a sidecar pattern requires direct SG injection (current design relies on EKS-cluster-SG ingress instead)."
  value       = aws_security_group.pg17.id
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master-user Secrets Manager secret. Bootstrap-only — Vault rotates the master credential post-deploy and vends short-lived per-role creds at runtime."
  value       = aws_db_instance.pg17.master_user_secret[0].secret_arn
  sensitive   = true
}

output "db_name" {
  description = "Initial database name (workshop) created at RDS provisioning."
  value       = aws_db_instance.pg17.db_name
}

output "master_username" {
  description = "RDS master username (vault_root). Phase 3 Vault PostgreSQL secrets engine connection uses this as the connection_url's user."
  value       = aws_db_instance.pg17.username
}

output "postgresql_log_group_name" {
  description = "Pre-created CloudWatch log group name for postgresql exports — Phase 6 audit-correlation Glue table targets this group."
  value       = aws_cloudwatch_log_group.rds_postgresql.name
}

output "postgresql_log_group_arn" {
  description = "Pre-created CloudWatch log group ARN — referenced by IAM policies that grant pgaudit-log read access to the audit-correlation query principal."
  value       = aws_cloudwatch_log_group.rds_postgresql.arn
}
