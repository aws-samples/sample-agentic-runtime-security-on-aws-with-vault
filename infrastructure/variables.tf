################################################################################
# Root Module — Input Variables (tier 1, core infrastructure)
#
# IVIA credentials, the .acme-state path, container image URIs, and
# bedrock_model_id moved to the tier-2 (infrastructure/services/) and tier-3
# (infrastructure/workloads/) roots — they are only consumed by the modules
# that moved there.
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
  description = "List of availability zones for the VPC subnets (3 AZs to match Vault Raft topology)."
}

#-------------------------------------------------------------------------------
# EKS Cluster Access
#-------------------------------------------------------------------------------

variable "admin_principal_arn" {
  type        = string
  description = "ARN of IAM user/role for kubectl access to the EKS cluster."
}

variable "enable_edr" {
  type        = bool
  description = "Deploy Uptycs KSPM EDR (k8sosquery DaemonSet + kubequery Deployment). Enable for HC-COMPUTE-011 compliance; disable for environments that don't require EDR."
  default     = false
}

#-------------------------------------------------------------------------------
# Audit Configuration
#-------------------------------------------------------------------------------

variable "audit_retention_days" {
  type        = number
  description = "CloudWatch log group retention in days for /workshop/* audit log groups."
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
# Attendee-trusted TLS via nip.io + Let's Encrypt
# acme_email: Let's Encrypt ACME account contact email — OPTIONAL. Empty (the
#   default) registers the ACME account with NO contact address; Let's Encrypt
#   turned off expiration-notice emails and DELETED all stored ACME account
#   emails on 2025-06-04, and accepts no-contact accounts. This is not an
#   identity/auth value, so an empty default carries no identity-fallback risk.
#   Consumed by the cert-manager ClusterIssuer in module.addons, which omits the
#   email key entirely when this is empty. The .acme-state file written by
#   deploy-workshop.sh is read by the tier-2 services root (IVIA nip.io FQDN).
#-------------------------------------------------------------------------------

variable "acme_email" {
  type        = string
  description = "Let's Encrypt ACME account contact email. Optional (default empty) — empty registers a no-contact account (LE deprecated account emails 2025-06-04). Consumed by the cert-manager ClusterIssuer in module.addons, which omits spec.acme.email when empty."
  default     = ""
}

#-------------------------------------------------------------------------------
# Image Source Toggle
# Controls whether EKS workloads use the local-build → private ECR path (default)
# or pull pre-built public GHCR images (opt-out).
# ecr:  local-build → push flow; ECR repos provisioned by the ecr module;
#       bootstrap stamps <account>/<region> URIs into tier-3 tfvars.
# ghcr: no container runtime required; imagePullPolicy IfNotPresent; ECR repos
#       not provisioned; bootstrap does not stamp image URIs.
# The registry base var is tier-3 only (workloads root); ECR does not consume it.
#-------------------------------------------------------------------------------

variable "image_source" {
  type        = string
  description = "Image source mode: 'ecr' (default — build the five Use Case images locally and push them to the account's private ECR; requires a container runtime) or 'ghcr' (opt-out — pull pre-built public images from GHCR, no build)."
  default     = "ecr"

  validation {
    condition     = contains(["ghcr", "ecr"], var.image_source)
    error_message = "image_source must be 'ghcr' or 'ecr'."
  }
}

#-------------------------------------------------------------------------------
# Resource Tags
#-------------------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
