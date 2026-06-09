################################################################################
# Root Module — Outputs (tier 1, core infrastructure)
#
# These outputs are the contract the downstream tiers read via
# terraform_remote_state (backend local, ../terraform.tfstate):
#   - infrastructure/services/  (tier 2: vault_server + ivia)
#   - infrastructure/workloads/ (tier 3: uc1/uc2/uc3)
#   - infrastructure/vault-config/ (Vault provider over kubectl port-forward)
################################################################################

#-------------------------------------------------------------------------------
# EKS Outputs (kubeconfig + downstream provider configuration)
#-------------------------------------------------------------------------------

output "cluster_name" {
  description = "Name of the EKS cluster. Consumed by tier-2/tier-3 provider exec (aws eks get-token) and by the IVIA module."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server. Consumed by tier-2/tier-3 kubernetes/helm/kubectl providers."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 EKS cluster CA. Consumed by tier-2/tier-3 providers and vault-config's Kubernetes auth backend config."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_issuer" {
  description = "EKS OIDC issuer URL. Consumed by vault-config for the Kubernetes auth backend config."
  value       = module.eks.cluster_oidc_issuer
}

output "node_security_group_id" {
  description = "EKS node security group ID. Consumed by the tier-2 IVIA module."
  value       = module.eks.node_security_group_id
}

output "kubectl_config_command" {
  description = "One-liner to configure kubectl. Run on the attendee laptop after apply."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias workshop"
}

#-------------------------------------------------------------------------------
# VPC Outputs
#-------------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block. Consumed by tier-3 uc2/uc3 modules as rds_cidr for egress NetworkPolicy rules."
  value       = module.vpc.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private subnet IDs (used by EKS managed nodes, RDS, AOSS interface endpoints)."
  value       = module.vpc.private_subnet_ids
}

#-------------------------------------------------------------------------------
# RDS Outputs (consumed by vault-config + tier-3 uc1/uc2/uc3 + teardown.sh)
#-------------------------------------------------------------------------------

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port). Consumed by vault-config."
  value       = module.rds.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL host (no port). Consumed by tier-3 uc1/uc2/uc3 modules."
  value       = module.rds.address
}

output "rds_port" {
  description = "RDS PostgreSQL port. Consumed by tier-3 uc1/uc2 modules."
  value       = module.rds.port
}

output "rds_db_name" {
  description = "RDS PostgreSQL database name. Consumed by tier-3 uc1/uc2 modules."
  value       = module.rds.db_name
}

output "rds_master_username" {
  description = "RDS PostgreSQL master username. Read by teardown.sh for the ivia_hvdb cleanup psql command (SC5 zero orphans)."
  value       = module.rds.master_username
}

output "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master password. Read by teardown.sh to extract the password for the ivia_hvdb DROP commands."
  value       = module.rds.master_user_secret_arn
  sensitive   = true
}

#-------------------------------------------------------------------------------
# Bedrock Knowledge Base Outputs
#-------------------------------------------------------------------------------

output "kb_id" {
  description = "Bedrock Knowledge Base ID — tier-3 uc1/uc2 agents pass this to bedrock-agent-runtime:Retrieve (us-east-1)."
  value       = module.bedrock_kb_index.knowledge_base_id
}

output "bedrock_role_arn" {
  description = "IAM role ARN Vault assumes for scoped Bedrock STS credentials (aws/sts backend). Consumed by vault-config."
  value       = module.bedrock_kb_aoss.kb_role_arn
}

#-------------------------------------------------------------------------------
# Audit Outputs
#-------------------------------------------------------------------------------

output "workshop_cmk_arn" {
  description = "Workshop CMK ARN. Reused for RDS storage encryption, AOSS encryption policy, S3 corpus SSE, and CloudWatch log group encryption."
  value       = module.audit.workshop_cmk_arn
}

output "audit_log_groups" {
  description = "Map of audit-source name → CloudWatch log group ARN. Keys: vault-audit, ivia-decision, agent-trace."
  value       = module.audit.audit_log_groups
}

output "glue_database_name" {
  description = "Glue catalog database for cross-plane Athena audit-correlation queries (workshop_logs)."
  value       = module.audit.glue_database_name
}

#-------------------------------------------------------------------------------
# Vault IAM / KMS Outputs (tier 1)
#-------------------------------------------------------------------------------

output "vault_unseal_kms_key_id" {
  description = "Key ID of the dedicated Vault unseal KMS key. Consumed by the tier-2 vault_server module to render the Vault seal \"awskms\" stanza."
  value       = module.vault_iam.vault_unseal_kms_key_id
}

output "uc3_logs_role_arn" {
  description = "IAM role ARN Vault assumes for scoped CloudWatch Logs STS creds (aws/sts/uc3-logs-writer). Consumed by vault-config."
  value       = aws_iam_role.uc3_logs_writer.arn
}

#-------------------------------------------------------------------------------
# TLS — stable workshop ACM ARN
# Consumed by tier-2 IVIA + tier-3 banking-ui Ingress annotations, by
# deploy-workshop.sh ACME step (aws acm import-certificate --certificate-arn),
# and by verify-tls.sh. Preserved across LE renewals via
# lifecycle.ignore_changes on aws_acm_certificate.workshop_tls.
#-------------------------------------------------------------------------------

output "tls_certificate_arn" {
  description = "Stable ACM ARN for the workshop TLS cert. Consumed by tier-2/tier-3 Ingress annotations + deploy-workshop.sh ACME step; preserved across LE renewals via lifecycle.ignore_changes."
  value       = local.tls_certificate_arn
}

#-------------------------------------------------------------------------------
# Region — consumed by tier-2/tier-3 providers + vault-config
#-------------------------------------------------------------------------------

output "region" {
  description = "AWS region. Consumed by tier-2/tier-3 provider exec + vault-config aws provider / secrets / sts backends."
  value       = var.region
}

output "kb_region" {
  description = "Knowledge Base region (us-east-1). Consumed by tier-3 uc1/uc2 agents for the bedrock-agent-runtime:Retrieve endpoint."
  value       = var.kb_region
}

output "tags" {
  description = "Resource tag map. Exported as the single source of truth so tier-2/tier-3 roots inherit identical tags via remote_state instead of re-declaring var.tags."
  value       = var.tags
}
