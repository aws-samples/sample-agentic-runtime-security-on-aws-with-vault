################################################################################
# Single-Region Deployment Configuration
# Agentic Runtime Security Workshop deploys to us-west-2 only.
# Reference: ~/git-repos/eks-terraform-stacks/infrastructure/deployments.tfdeploy.hcl
#
# CANONICAL REGION CONTRACT
# The string literal "us-west-2" appears ONLY in this file — every component
# receives var.region from here. Lint check (Pitfall T1):
#   grep -rn 'us-west-2' --include='*.tf' --include='*.hcl' \
#     --include='*.tfcomponent.hcl' --include='*.tfdeploy.hcl' infrastructure/
# should return matches ONLY in deployments.tfdeploy.hcl.
################################################################################

#-------------------------------------------------------------------------------
# OIDC Authentication for AWS
# HCP Terraform uses this token to assume the AWS IAM role.
#-------------------------------------------------------------------------------

identity_token "aws" {
  audience = ["aws.workload.identity"]
}

################################################################################
# Variable Set Configuration
# Created by scripts/bootstrap.sh — contains aws_role_arn and admin_principal_arn.
# See infrastructure/scripts/bootstrap.sh for setup instructions.
################################################################################

store "varset" "config" {
  name     = "agentic-runtime-stacks-config"
  category = "terraform"
}

################################################################################
# Note: store and identity_token values are referenced directly in deployment
# inputs because Stacks locals can only reference other locals.
################################################################################

#-------------------------------------------------------------------------------
# Auto-Approve Rule
# Automatically approve plans that do not destroy resources.
# Plans that remove any resources require manual approval in HCP Terraform.
# Note: Auto-approve orchestration enforcement requires HCP Terraform Premium tier.
# On Standard/Essentials tiers, the rule is defined but plans require manual approval.
#-------------------------------------------------------------------------------

deployment_auto_approve "no_destroy" {
  check {
    condition = context.plan.changes.remove == 0
    reason    = "Plan removes ${context.plan.changes.remove} resources. Destroys require manual approval."
  }
}

################################################################################
# Deployment Group (single region — usw2 only)
# GA limitation: one deployment per group (1:1 mapping required).
################################################################################

deployment_group "usw2" {
  auto_approve_checks = [deployment_auto_approve.no_destroy]
}

#-------------------------------------------------------------------------------
# US West (Oregon) - us-west-2
# THE ONLY deployment block. Single-region by deliberate Phase 1 decision
# (see PROJECT.md Key Decisions).
#-------------------------------------------------------------------------------

deployment "usw2" {
  destroy          = false
  deployment_group = deployment_group.usw2

  inputs = {
    # Canonical region — every component receives this via var.region.
    region = "us-west-2"

    cluster_name = "agentic-runtime-usw2"
    vpc_cidr     = "10.1.0.0/16"
    azs          = ["us-west-2a", "us-west-2b", "us-west-2c"]

    # Bedrock KB region — Nova 2 Multimodal Embeddings is us-east-1 only.
    kb_region = "us-east-1"

    # Audit retention (workshop ephemeral; 7-day default)
    audit_retention_days = 7

    # RDS sizing (db.t3.medium for ≤15 attendees per CONTEXT)
    rds_instance_class = "db.t3.medium"

    tags = {
      Environment = "workshop"
      Workshop    = "agentic-runtime-security"
      Region      = "us-west-2"
      ManagedBy   = "terraform-stacks"
    }

    # IBM Container Registry entitlement key for IVIA images
    icr_entitlement_key = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJJQk0gTWFya2V0cGxhY2UiLCJpYXQiOjE3NzgyODQwNDksImp0aSI6IjZkZjJkNWY5M2NlYjRmZWE5YThlNWM2ODI5MWM3MzQ2In0.UHv4IX0FFa7ASBWf4Txclhfz-52ZTjMwixXdFxtAWsA"

    # UC1 Agent image — attendees set this after ECR push (Phase 4 lab step).
    # Replace with the actual ECR URI: <account>.dkr.ecr.us-west-2.amazonaws.com/uc1-agent:<tag>
    uc1_agent_image = "<placeholder-ecr-uri>"

    # OIDC authentication
    role_arn       = store.varset.config.aws_role_arn
    identity_token = identity_token.aws.jwt

    # Admin access (.stable persists in state — value is immutable once set)
    admin_principal_arn = store.varset.config.stable.admin_principal_arn
  }
}
