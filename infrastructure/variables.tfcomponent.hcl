################################################################################
# Terraform Stacks - Stack-Level Variables
# Agentic Runtime Security Workshop — Phase 2 Foundation
# Reference: ~/git-repos/eks-terraform-stacks/infrastructure/variables.tfcomponent.hcl
#
# All variables referenced from deployments.tfdeploy.hcl inputs MUST be declared here.
################################################################################

#-------------------------------------------------------------------------------
# AWS Authentication (OIDC)
# Provided by HCP Terraform variable set 'agentic-runtime-stacks-config'.
#-------------------------------------------------------------------------------

variable "region" {
  type        = string
  description = "AWS region for deployment. Canonical region — every component receives this. The string literal MUST appear only in deployments.tfdeploy.hcl."
}

variable "role_arn" {
  type        = string
  ephemeral   = true
  description = "ARN of the IAM role for HCP Terraform to assume via OIDC."
}

variable "identity_token" {
  type        = string
  ephemeral   = true
  description = "OIDC identity token from HCP Terraform."
}

#-------------------------------------------------------------------------------
# EKS Cluster Configuration
#-------------------------------------------------------------------------------

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster (also used for VPC + RDS naming)."
}

#-------------------------------------------------------------------------------
# VPC Configuration
#-------------------------------------------------------------------------------

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC (default 10.1.0.0/16)."
}

variable "azs" {
  type        = list(string)
  description = "List of availability zones for the VPC subnets (3 AZs to match Vault Raft topology in Phase 3)."
}

#-------------------------------------------------------------------------------
# EKS Cluster Access
#-------------------------------------------------------------------------------

variable "admin_principal_arn" {
  type        = string
  description = "ARN of IAM user/role for kubectl access to the EKS cluster. Provided via HCP Terraform variable set."
}

#-------------------------------------------------------------------------------
# Audit Configuration
#-------------------------------------------------------------------------------

variable "audit_retention_days" {
  type        = number
  description = "CloudWatch log group retention in days for /workshop/* audit log groups (Pitfall R2 mitigation: short retention controls workshop ingestion costs)."
  default     = 7
}

#-------------------------------------------------------------------------------
# RDS Configuration
#-------------------------------------------------------------------------------

variable "rds_instance_class" {
  type        = string
  description = "RDS instance class. db.t3.medium for ≤15 attendees (default per CONTEXT); db.t3.large for >15."
  default     = "db.t3.medium"
}

#-------------------------------------------------------------------------------
# Resource Tags
#-------------------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
