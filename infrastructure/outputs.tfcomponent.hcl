################################################################################
# Stack-Level Outputs
# Agentic Runtime Security Workshop — Phase 2 Foundation
# Exposed in HCP Terraform UI per deployment.
# Reference: ~/git-repos/eks-terraform-stacks/infrastructure/outputs.tfcomponent.hcl
################################################################################

#-------------------------------------------------------------------------------
# EKS Outputs (for kubeconfig setup)
#-------------------------------------------------------------------------------

output "cluster_name" {
  type        = string
  description = "Name of the EKS cluster."
  value       = component.eks.cluster_name
}

output "cluster_endpoint" {
  type        = string
  description = "Endpoint for the EKS cluster API server."
  value       = component.eks.cluster_endpoint
}

output "kubectl_config_command" {
  type        = string
  description = "One-liner to configure kubectl. Copy this from HCP Terraform UI and run on attendee laptop."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${component.eks.cluster_name} --alias workshop"
}

#-------------------------------------------------------------------------------
# VPC Outputs (consumed by downstream phases for security group / route lookups)
#-------------------------------------------------------------------------------

output "vpc_id" {
  type        = string
  description = "ID of the VPC."
  value       = component.vpc.vpc_id
}

output "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (used by EKS managed nodes, RDS, AOSS interface endpoints)."
  value       = component.vpc.private_subnet_ids
}

#-------------------------------------------------------------------------------
# RDS Outputs (consumed by Phase 3 Vault config + Phase 5 UC3 agent)
#-------------------------------------------------------------------------------

output "rds_endpoint" {
  type        = string
  description = "RDS PostgreSQL endpoint (host:port)."
  value       = component.rds.endpoint
}

# --- Bedrock KB output temporarily removed for region migration (step 1/2).
# output "kb_id" {
#   type        = string
#   description = "Bedrock Knowledge Base ID — agents pass this to bedrock-agent-runtime:Retrieve."
#   value       = component.bedrock_kb_index.knowledge_base_id
# }

#-------------------------------------------------------------------------------
# Audit Outputs (consumed by every downstream phase that emits logs)
#-------------------------------------------------------------------------------

output "workshop_cmk_arn" {
  type        = string
  description = "Workshop CMK ARN. Reused for RDS storage encryption, AOSS encryption policy, S3 corpus SSE, and CloudWatch log group encryption."
  value       = component.audit.workshop_cmk_arn
}

output "audit_log_groups" {
  type        = map(string)
  description = "Map of audit-source name → CloudWatch log group ARN. Keys: vault-audit, ivia-decision, agent-trace. Phase 3 fluent-bit configs reference these by ARN."
  value       = component.audit.audit_log_groups
}

output "glue_database_name" {
  type        = string
  description = "Glue catalog database for cross-plane Athena audit-correlation queries (workshop_logs). Phase 6 adds tables."
  value       = component.audit.glue_database_name
}
