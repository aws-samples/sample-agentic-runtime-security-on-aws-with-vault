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
# Simple AD Outputs (consumed by configure-workshop.sh for user provisioning)
#-------------------------------------------------------------------------------

# output "simple_ad_dns_ips" {
#   description = "DNS IP addresses of the Simple AD directory. Used by IVIA for LDAP and by create-simple-ad-users.sh."
#   value       = module.simple_ad.dns_ip_addresses
# }
#
# output "simple_ad_base_dn" {
#   description = "LDAP base DN for Simple AD user lookups (e.g. CN=Users,DC=workshop,DC=internal)."
#   value       = module.simple_ad.base_dn
# }
