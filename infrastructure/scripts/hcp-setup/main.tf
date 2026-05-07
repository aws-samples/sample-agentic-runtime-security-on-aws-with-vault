################################################################################
# HCP Terraform Project + Variable Set — Agentic Runtime Security workshop
#
# Creates the project under the workshop attendee's HCP org, plus a variable
# set bound to that project. The variable set carries the AWS OIDC role ARN,
# region, and admin principal ARN that the workshop's Stacks deployment reads
# at runtime via store.varset.config.<key>.
#
# Driven by infrastructure/scripts/bootstrap.sh (writes terraform.tfvars from
# environment-derived values, then runs terraform init + apply here).
#
# Mirrors the structure of:
#   ~/git-repos/eks-terraform-stacks/infrastructure/scripts/hcp-setup/main.tf
################################################################################

terraform {
  # The hcp-setup module only uses the tfe provider (HCP project + variable set).
  # It does NOT use Stacks features, so it does not need Terraform 1.10+.
  # Matches eks-terraform-stacks/infrastructure/scripts/hcp-setup/versions.tf,
  # which also pins ">= 1.0" so attendees with stock Terraform CLIs can bootstrap.
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
provider "tfe" {
  # hostname defaults to app.terraform.io
}

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

variable "aws_region" {
  type        = string
  description = "AWS region for the workshop deployment. Single-region per CONTEXT.md; canonical value lives in deployments.tfdeploy.hcl and is mirrored into the variable set by bootstrap.sh."
}

variable "iam_role_arn" {
  type        = string
  description = "ARN of the IAM role HCP Stacks assumes via OIDC (created by bootstrap.sh Step 2)"

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.iam_role_arn))
    error_message = "iam_role_arn must be a valid IAM role ARN (arn:aws:iam::ACCOUNT:role/NAME)."
  }
}

variable "admin_principal_arn" {
  type        = string
  description = "Workshop attendee's IAM principal ARN — granted EKS access entry (cluster-admin) by the Stacks deployment"
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

#-------------------------------------------------------------------------------
# Project — workshop-scoped HCP project that owns the Stack
#-------------------------------------------------------------------------------
resource "tfe_project" "workshop" {
  organization = var.hcp_org
  name         = var.project_name
  description  = "Agentic Runtime Security on AWS workshop — Stacks-managed single-region deployment (canonical region locked in deployments.tfdeploy.hcl)"

  # The TFE API lowercases the organization name on return (e.g. "DevOpsOscar"
  # → "devopsoscar"), causing Terraform to see an inconsistent result.
  # Mirrors the workaround in the reference repo's hcp-setup/main.tf.
  lifecycle {
    ignore_changes = [organization]
  }
}

#-------------------------------------------------------------------------------
# Variable Set — project-scoped (bound to the workshop project, not org-wide)
#
# Note: `parent_project_id` was added to the tfe provider in v0.55+. This
# binds the variable set to the project so all workspaces / Stacks under the
# project automatically inherit it. The same field replaces the separate
# `tfe_project_variable_set` assignment resource the older reference repo used.
#-------------------------------------------------------------------------------
resource "tfe_variable_set" "workshop" {
  organization      = var.hcp_org
  name              = var.varset_name
  description       = "Variable set for the Agentic Runtime Security workshop Stacks deployment (OIDC role ARN, region, admin ARN)"
  parent_project_id = tfe_project.workshop.id
}

#-------------------------------------------------------------------------------
# Variables in the variable set
#
# All `category = "terraform"` (HCL variables, not env). Stacks deployments
# read them at runtime via `store.varset.<varset>.<key>`.
#-------------------------------------------------------------------------------
resource "tfe_variable" "aws_role_arn" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "aws_role_arn"
  value           = var.iam_role_arn
  category        = "terraform"
  description     = "IAM role ARN HCP Stacks assumes via OIDC for workshop deploys"
}

resource "tfe_variable" "aws_region" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "aws_region"
  value           = var.aws_region
  category        = "terraform"
  description     = "AWS region (single-region workshop; canonical value lives in deployments.tfdeploy.hcl)"
}

resource "tfe_variable" "admin_principal_arn" {
  variable_set_id = tfe_variable_set.workshop.id
  key             = "admin_principal_arn"
  value           = var.admin_principal_arn
  category        = "terraform"
  description     = "Workshop attendee IAM principal ARN — granted cluster-admin via EKS access entry"
}

#-------------------------------------------------------------------------------
# Outputs — consumed by bootstrap.sh Step 7 (Stack creation + variable-set
# assignment)
#-------------------------------------------------------------------------------
output "project_id" {
  value       = tfe_project.workshop.id
  description = "HCP project ID — passed to POST /stacks as relationships.project.data.id"
}

output "varset_id" {
  value       = tfe_variable_set.workshop.id
  description = "HCP variable set ID — used by POST /varsets/$VS/relationships/stacks"
}

output "project_name" {
  value       = tfe_project.workshop.name
  description = "HCP project name (echoed for bootstrap.sh summary block)"
}

output "varset_name" {
  value       = tfe_variable_set.workshop.name
  description = "HCP variable set name (echoed for bootstrap.sh summary block)"
}
