################################################################################
# Root Module — Input Variables
# Agentic Runtime Security Workshop
# Migrated from Stacks variables.tfcomponent.hcl → standard Terraform variables.tf
#
# Removed from Stacks version:
#   - role_arn (Stacks OIDC auth — attendees use local AWS creds)
#   - identity_token (Stacks OIDC auth — attendees use local AWS creds)
#   - ephemeral = true attributes (Stacks-specific syntax)
################################################################################

#-------------------------------------------------------------------------------
# Region Configuration
#-------------------------------------------------------------------------------

variable "region" {
  type        = string
  description = "AWS region for deployment. Canonical region — every module receives this. The string literal appears only in terraform.tfvars."
}

variable "kb_region" {
  type        = string
  description = "AWS region for Bedrock KB components (AOSS, KB, corpus). Nova 2 Multimodal Embeddings is us-east-1 only; everything else stays in var.region."
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
  description = "ARN of IAM user/role for kubectl access to the EKS cluster."
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

#-------------------------------------------------------------------------------
# UC1 Agent Configuration
# uc1_agent_image: set by attendees after ECR push (Phase 4 lab step).
# bedrock_model_id: defaults to Nova Pro CRIS profile — no tfvars override needed.
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
# UC2 Banking App Configuration
# 3 images: set by attendees after ECR push (Phase 5 lab step).
# Single ECR repo with :ui, :agent, :mcp tags.
#-------------------------------------------------------------------------------

variable "banking_app_ui_image" {
  type        = string
  description = "ECR image URI for the banking app UI container (tag: ui)."
}

variable "banking_app_agent_image" {
  type        = string
  description = "ECR image URI for the banking app agent container (tag: agent)."
}

variable "banking_app_mcp_image" {
  type        = string
  description = "ECR image URI for the banking app MCP server container (tag: mcp)."
}

#-------------------------------------------------------------------------------
# Simple AD (LDAP identity source for IVIA)
#-------------------------------------------------------------------------------

variable "simple_ad_admin_password" {
  type        = string
  sensitive   = true
  default     = "WorkshopAdmin1!"
  description = "Administrator password for AWS Simple AD. Used for LDAP bind and user provisioning."
}

variable "uc2_redirect_uri" {
  type        = string
  default     = "http://localhost:3000/callback"
  description = "OAuth redirect URI for UC2 banking app. Set to ALB hostname after deploy."
}

#-------------------------------------------------------------------------------
# UC3 Agent Configuration
# uc3_agent_image: set by attendees after ECR push (Phase 6 lab step).
# ivia_uc3_client_secret: IVIA OAuth client secret for agent-uc3 (CIBA-capable).
#-------------------------------------------------------------------------------

variable "uc3_agent_image" {
  type        = string
  description = "ECR image URI for the UC3 privileged-action agent container. Built from applications/uc3-agent/Dockerfile."
}

variable "ivia_uc3_client_secret" {
  type        = string
  sensitive   = true
  description = "IVIA OAuth client secret for agent-uc3. CIBA backchannel auth; stored in ConfigMap for workshop simplicity."
}

#-------------------------------------------------------------------------------
# Resource Tags
#-------------------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
