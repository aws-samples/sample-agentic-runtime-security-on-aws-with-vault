################################################################################
# HCP Terraform Project + Variable Set — Agentic Runtime Security workshop
#
# Creates the project under the workshop attendee's HCP org, plus a variable
# set bound to that project. Local execution mode — the variable set holds
# only sensitive values that should not be in terraform.tfvars on disk.
# All other variables are read from local terraform.tfvars.
#
# Driven by infrastructure/scripts/bootstrap.sh.
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

variable "icr_entitlement_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "IBM Container Registry entitlement key for IVIA images"
}

variable "simple_ad_admin_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Simple AD Administrator password for LDAP bind + user provisioning"
}

#-------------------------------------------------------------------------------
# Project
#-------------------------------------------------------------------------------
resource "tfe_project" "workshop" {
  organization = var.hcp_org
  name         = var.project_name
  description  = "Agentic Runtime Security on AWS workshop — local execution, HCP state backend"

  lifecycle {
    ignore_changes = [organization]
  }
}

#-------------------------------------------------------------------------------
# Variable Set — sensitive-only variables, assigned to the workshop project.
# Workspaces under the project inherit these automatically.
#-------------------------------------------------------------------------------
resource "tfe_variable_set" "workshop" {
  organization = var.hcp_org
  name         = var.varset_name
  description  = "Sensitive variables for the Agentic Runtime Security workshop (icr_entitlement_key, simple_ad_admin_password)."
}

resource "tfe_project_variable_set" "assign_to_project" {
  project_id      = tfe_project.workshop.id
  variable_set_id = tfe_variable_set.workshop.id
}

#-------------------------------------------------------------------------------
# Sensitive variables only — everything else is in terraform.tfvars locally
#-------------------------------------------------------------------------------

resource "tfe_variable" "icr_entitlement_key" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "icr_entitlement_key"
  value           = var.icr_entitlement_key
  category        = "terraform"
  sensitive       = true
  description     = "IBM Container Registry entitlement key (sensitive)"
}

resource "tfe_variable" "simple_ad_admin_password" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "simple_ad_admin_password"
  value           = var.simple_ad_admin_password
  category        = "terraform"
  sensitive       = true
  description     = "Simple AD Administrator password (sensitive)"
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
