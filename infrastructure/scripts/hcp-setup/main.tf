################################################################################
# HCP Terraform Project + Variable Set — Agentic Runtime Security workshop
#
# Creates the project under the workshop attendee's HCP org, plus a variable
# set bound to that project. The variable set carries ALL Terraform variables
# the root module (infrastructure/) requires. Remote execution mode means the
# HCP worker never sees local terraform.tfvars — every value must be here.
#
# Driven by infrastructure/scripts/bootstrap.sh (writes terraform.tfvars from
# environment-derived values, then runs terraform init + apply here).
#
# Mirrors the structure of:
#   ~/git-repos/eks-terraform-stacks/infrastructure/scripts/hcp-setup/main.tf
################################################################################

terraform {
  required_version = ">= 1.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.65"
    }
  }
}

#-------------------------------------------------------------------------------
# Provider — token comes from TFE_TOKEN env var (loaded by bootstrap.sh from
# ~/.terraform.d/credentials.tfrc.json after `terraform login`)
#-------------------------------------------------------------------------------
provider "tfe" {}

#-------------------------------------------------------------------------------
# Input variables
#-------------------------------------------------------------------------------
variable "hcp_org" {
  type        = string
  description = "HCP Terraform organization name"
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID (12 digits) hosting the workshop deploys"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "iam_role_arn" {
  type        = string
  description = "ARN of the IAM role HCP assumes via OIDC (created by bootstrap.sh Step 2)"

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.iam_role_arn))
    error_message = "iam_role_arn must be a valid IAM role ARN (arn:aws:iam::ACCOUNT:role/NAME)."
  }
}

variable "admin_principal_arn" {
  type        = string
  description = "Workshop attendee's IAM principal ARN — granted EKS access entry (cluster-admin)"
}

variable "project_name" {
  type        = string
  default     = "Agentic Runtime Security"
  description = "HCP project name"
}

variable "varset_name" {
  type        = string
  default     = "agentic-runtime-stacks-config"
  description = "HCP variable set name"
}

# --- Root module variables (mirrored into variable set) ---

variable "region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region for deployment"
}

variable "kb_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for Bedrock KB components (Nova 2 Embeddings is us-east-1 only)"
}

variable "cluster_name" {
  type        = string
  default     = "agentic-runtime-usw2"
  description = "EKS cluster name"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.1.0.0/16"
  description = "VPC CIDR block"
}

variable "azs" {
  type        = string
  default     = "[\"us-west-2a\",\"us-west-2b\",\"us-west-2c\"]"
  description = "JSON-encoded list of availability zones (HCL list variable in HCP)"
}

variable "icr_entitlement_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "IBM Container Registry entitlement key for IVIA images"
}

variable "uc1_agent_image" {
  type        = string
  default     = "placeholder"
  description = "ECR image URI for UC1 agent (set after ECR push)"
}

variable "banking_app_ui_image" {
  type        = string
  default     = "placeholder"
  description = "ECR image URI for banking app UI (set after ECR push)"
}

variable "banking_app_agent_image" {
  type        = string
  default     = "placeholder"
  description = "ECR image URI for banking app agent (set after ECR push)"
}

variable "banking_app_mcp_image" {
  type        = string
  default     = "placeholder"
  description = "ECR image URI for banking app MCP server (set after ECR push)"
}

variable "simple_ad_admin_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Simple AD Administrator password for LDAP bind + user provisioning"
}

variable "uc2_redirect_uri" {
  type        = string
  default     = "http://localhost:3000/callback"
  description = "OAuth redirect URI for UC2 banking app (set after ALB provisioned)"
}

#-------------------------------------------------------------------------------
# Project
#-------------------------------------------------------------------------------
resource "tfe_project" "workshop" {
  organization = var.hcp_org
  name         = var.project_name
  description  = "Agentic Runtime Security on AWS workshop — remote execution workspace"

  lifecycle {
    ignore_changes = [organization]
  }
}

#-------------------------------------------------------------------------------
# Variable Set — organization-scoped, assigned to the workshop project.
# Workspaces under the project inherit all variables automatically.
#-------------------------------------------------------------------------------
resource "tfe_variable_set" "workshop" {
  organization = var.hcp_org
  name         = var.varset_name
  description  = "All Terraform variables for the Agentic Runtime Security workshop workspace (remote execution)."
}

resource "tfe_project_variable_set" "assign_to_project" {
  project_id      = tfe_project.workshop.id
  variable_set_id = tfe_variable_set.workshop.id
}

#-------------------------------------------------------------------------------
# Variables in the variable set
#
# category = "terraform" → HCL variables (var.X in root module)
# Keys MUST match the root module's variable names exactly.
#-------------------------------------------------------------------------------

# --- Dynamic provider credentials (env vars, not terraform vars) ---
# HCP Terraform injects OIDC token + STS web identity transparently when these
# are set. The AWS provider block stays minimal (region only).
resource "tfe_variable" "tfc_aws_provider_auth" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "TFC_AWS_PROVIDER_AUTH"
  value           = "true"
  category        = "env"
  description     = "Enable HCP Terraform dynamic AWS credentials (OIDC)"
}

resource "tfe_variable" "tfc_aws_run_role_arn" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "TFC_AWS_RUN_ROLE_ARN"
  value           = var.iam_role_arn
  category        = "env"
  description     = "IAM role ARN HCP assumes via OIDC for plan/apply"
}

# --- Region ---
resource "tfe_variable" "region" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "region"
  value           = var.region
  category        = "terraform"
  description     = "AWS region (single-region workshop)"
}

resource "tfe_variable" "kb_region" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "kb_region"
  value           = var.kb_region
  category        = "terraform"
  description     = "AWS region for Bedrock KB (Nova 2 Embeddings is us-east-1 only)"
}

# --- Cluster + Network ---
resource "tfe_variable" "cluster_name" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "cluster_name"
  value           = var.cluster_name
  category        = "terraform"
  description     = "EKS cluster name"
}

resource "tfe_variable" "vpc_cidr" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "vpc_cidr"
  value           = var.vpc_cidr
  category        = "terraform"
  description     = "VPC CIDR block"
}

resource "tfe_variable" "azs" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "azs"
  value           = var.azs
  category        = "terraform"
  hcl             = true
  description     = "Availability zones (list)"
}

# --- EKS Access ---
resource "tfe_variable" "admin_principal_arn" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "admin_principal_arn"
  value           = var.admin_principal_arn
  category        = "terraform"
  description     = "Workshop attendee IAM principal ARN — cluster-admin via EKS access entry"
}

# --- IVIA ---
resource "tfe_variable" "icr_entitlement_key" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "icr_entitlement_key"
  value           = var.icr_entitlement_key
  category        = "terraform"
  sensitive       = true
  description     = "IBM Container Registry entitlement key (sensitive)"
}

# --- Container images (updated after ECR push) ---
resource "tfe_variable" "uc1_agent_image" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "uc1_agent_image"
  value           = var.uc1_agent_image
  category        = "terraform"
  description     = "ECR image URI for UC1 agent"
}

resource "tfe_variable" "banking_app_ui_image" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "banking_app_ui_image"
  value           = var.banking_app_ui_image
  category        = "terraform"
  description     = "ECR image URI for banking app UI"
}

resource "tfe_variable" "banking_app_agent_image" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "banking_app_agent_image"
  value           = var.banking_app_agent_image
  category        = "terraform"
  description     = "ECR image URI for banking app agent"
}

resource "tfe_variable" "banking_app_mcp_image" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "banking_app_mcp_image"
  value           = var.banking_app_mcp_image
  category        = "terraform"
  description     = "ECR image URI for banking app MCP server"
}

# --- Simple AD ---
resource "tfe_variable" "simple_ad_admin_password" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "simple_ad_admin_password"
  value           = var.simple_ad_admin_password
  category        = "terraform"
  sensitive       = true
  description     = "Simple AD Administrator password (sensitive)"
}

resource "tfe_variable" "uc2_redirect_uri" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "uc2_redirect_uri"
  value           = var.uc2_redirect_uri
  category        = "terraform"
  description     = "OAuth redirect URI for UC2 banking app"
}

#-------------------------------------------------------------------------------
# Outputs
#-------------------------------------------------------------------------------
output "project_id" {
  value       = tfe_project.workshop.id
  description = "HCP project ID"
}

output "varset_id" {
  value       = tfe_variable_set.workshop.id
  description = "HCP variable set ID"
}

output "project_name" {
  value       = tfe_project.workshop.name
  description = "HCP project name"
}

output "varset_name" {
  value       = tfe_variable_set.workshop.name
  description = "HCP variable set name"
}
