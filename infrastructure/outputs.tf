################################################################################
# Root Module — Outputs
# Agentic Runtime Security Workshop
# Migrated from Stacks outputs.tfcomponent.hcl → standard Terraform outputs.tf
#
# Changes from Stacks version:
#   - component.X.Y → module.X.Y
#   - type attribute removed (Stacks-specific; standard Terraform infers type)
################################################################################

#-------------------------------------------------------------------------------
# EKS Outputs (for kubeconfig setup)
#-------------------------------------------------------------------------------

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server."
  value       = module.eks.cluster_endpoint
}

output "kubectl_config_command" {
  description = "One-liner to configure kubectl. Run this on the attendee laptop after apply."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias workshop"
}

#-------------------------------------------------------------------------------
# VPC Outputs (consumed by downstream phases for security group / route lookups)
#-------------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (used by EKS managed nodes, RDS, AOSS interface endpoints)."
  value       = module.vpc.private_subnet_ids
}

#-------------------------------------------------------------------------------
# RDS Outputs (consumed by Phase 3 Vault config + Phase 5 UC3 agent)
#-------------------------------------------------------------------------------

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)."
  value       = module.rds.endpoint
}

#-------------------------------------------------------------------------------
# RDS master credentials — consumed by teardown.sh for ivia_hvdb role+schema
# cleanup (CONTEXT R3). The role was created by the legacy verify_access module's
# bootstrap Job and is orphaned when the module is replaced. teardown.sh runs
# DROP SCHEMA ... CASCADE; DROP ROLE ... idempotently against the shared RDS
# instance before module destroy.
#-------------------------------------------------------------------------------

output "rds_master_username" {
  description = "RDS PostgreSQL master username (master_username from module.rds). Read by infrastructure/scripts/teardown.sh for the ivia_hvdb cleanup psql command. Required for SC5 (zero orphans)."
  value       = module.rds.master_username
}

output "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master password. Read by infrastructure/scripts/teardown.sh; teardown invokes aws secretsmanager get-secret-value to extract the password for the ivia_hvdb DROP commands."
  value       = module.rds.master_user_secret_arn
  sensitive   = true
}

#-------------------------------------------------------------------------------
# Bedrock Knowledge Base Outputs
#-------------------------------------------------------------------------------

output "kb_id" {
  description = "Bedrock Knowledge Base ID — agents pass this to bedrock-agent-runtime:Retrieve (us-east-1)."
  value       = module.bedrock_kb_index.knowledge_base_id
}

#-------------------------------------------------------------------------------
# Audit Outputs (consumed by every downstream phase that emits logs)
#-------------------------------------------------------------------------------

output "workshop_cmk_arn" {
  description = "Workshop CMK ARN. Reused for RDS storage encryption, AOSS encryption policy, S3 corpus SSE, and CloudWatch log group encryption."
  value       = module.audit.workshop_cmk_arn
}

output "audit_log_groups" {
  description = "Map of audit-source name → CloudWatch log group ARN. Keys: vault-audit, ivia-decision, agent-trace. Phase 3 fluent-bit configs reference these by ARN."
  value       = module.audit.audit_log_groups
}

output "glue_database_name" {
  description = "Glue catalog database for cross-plane Athena audit-correlation queries (workshop_logs). Phase 6 adds tables."
  value       = module.audit.glue_database_name
}

#-------------------------------------------------------------------------------
# UC2 Banking UI Outputs (consumed by the kubernetes_job_v1.agent_uc2_dcr
# resource to build redirect_uri for the agent-uc2 OIDC client registration).
#-------------------------------------------------------------------------------

output "banking_ui_alb_hostname" {
  description = "Public ALB hostname for the UC2 banking UI Ingress. The agent_uc2_dcr Job uses this to build redirect_uri=\"http://<hostname>/callback\" when registering the agent-uc2 OAuth client via iviaop's RFC 7591 DCR endpoint."
  value       = module.uc2_app.banking_ui_alb_hostname
}

#-------------------------------------------------------------------------------
# vault-config inputs — consumed by the separate infrastructure/vault-config/
# Terraform root via data.terraform_remote_state.root (local backend, this
# state file). The vault-config root needs a live Vault provider over a
# kubectl port-forward, so it cannot be folded into this graph; instead it
# reads these outputs at its own apply time. This replaces the prior
# vault-configure.sh bash auto-detection + hand-written terraform.tfvars
# strings — the one class of value that cannot live here is the Vault root
# token (runtime secret), which vault-config keeps as its only external var.
#-------------------------------------------------------------------------------

output "region" {
  description = "AWS region. Consumed by the vault-config root for its aws provider + secrets/sts backends."
  value       = var.region
}

output "ivia_issuer" {
  description = "IVIA token issuer (https://<wrp-alb-host>). This is the EXACT value iviaop stamps into the iss claim (local.ivia_public_issuer also patches iviaop's provider.yml). vault-config wires it into the JWT auth backend's bound_issuer so the two can never drift after an IVIA rebuild."
  value       = local.ivia_public_issuer
}

output "ivia_oidc_ca_pem" {
  description = "IVIA OIDC Provider self-signed TLS cert. vault-config feeds it to the JWT auth backend as jwks_ca_pem so Vault trusts the cluster-internal JWKS endpoint. Static repo file — does not drift on rebuild."
  value       = module.ivia.ivia_oidc_ca_pem
}

output "cluster_certificate_authority_data" {
  description = "Base64 EKS cluster CA. Consumed by vault-config for the Kubernetes auth backend config."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_issuer" {
  description = "EKS OIDC issuer URL. Consumed by vault-config for the Kubernetes auth backend config."
  value       = module.eks.cluster_oidc_issuer
}

output "bedrock_role_arn" {
  description = "IAM role ARN Vault assumes for scoped Bedrock STS credentials (aws/sts backend). Consumed by vault-config."
  value       = module.bedrock_kb_aoss.kb_role_arn
}

output "uc3_logs_role_arn" {
  description = "IAM role ARN Vault assumes for scoped CloudWatch Logs STS creds (aws/sts/uc3-logs-writer). Consumed by vault-config."
  value       = aws_iam_role.uc3_logs_writer.arn
}
