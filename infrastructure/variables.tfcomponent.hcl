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

variable "kb_region" {
  type        = string
  description = "AWS region for Bedrock KB components (AOSS, KB, corpus). Nova 2 Multimodal Embeddings is us-east-1 only; everything else stays in var.region."
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
# IBM Verify Identity Access (IVIA) Configuration
#-------------------------------------------------------------------------------

variable "icr_entitlement_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "IBM Container Registry entitlement key for pulling IVIA images (icr.io/ivia/ivia-oidc-provider). Attendees obtain from IBM."
}

variable "ivia_activation_code" {
  type        = string
  sensitive   = true
  default     = ""
  description = "IVIA activation code (PEM certificate). Trial license from isva-trial.verify.ibm.com or production from Passport Advantage (M11DCML)."
}

#-------------------------------------------------------------------------------
# Vault Configuration
# vault_token: Vault root/initial token used ONLY for bootstrap config in
# vault_config component. Never used by UC agents (they use K8s auth).
# Ephemeral = true so the token is not stored in Stacks state.
# NOTE: rds_master_password is NOT here — vault_config fetches it from
#       Secrets Manager via rds_master_user_secret_arn + data source.
#-------------------------------------------------------------------------------

variable "vault_token" {
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = ""
  description = "Vault root token for initial vault_config bootstrap. Ephemeral — not stored in Stacks state. Rotated after first apply."
}

#-------------------------------------------------------------------------------
# IVIA Admin Credentials
# Used by the restapi provider in isva_config component (Wave 5) to
# authenticate to the IVIA Config Service REST API.
#-------------------------------------------------------------------------------

variable "ivia_admin_username" {
  type        = string
  description = "IVIA admin username for the Config Service REST API (default: admin)."
  default     = "admin"
}

variable "ivia_admin_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "IVIA admin password for the Config Service REST API. Provided via HCP Terraform variable set."
}

#-------------------------------------------------------------------------------
# UC1 Agent Configuration
# uc1_agent_image: set by attendees after ECR push (Phase 4 lab step).
# bedrock_model_id: defaults to Nova Pro CRIS profile — no deployments override needed.
#-------------------------------------------------------------------------------

variable "uc1_agent_image" {
  type        = string
  description = "ECR image URI for the UC1 agent container. Built from infrastructure/modules/uc1_agent/agent/Dockerfile."
}

variable "bedrock_model_id" {
  type        = string
  description = "Bedrock model ID for agent LLM calls. Uses cross-region inference profile."
  default     = "us.amazon.nova-pro-v1:0"
}

#-------------------------------------------------------------------------------
# Resource Tags
#-------------------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
