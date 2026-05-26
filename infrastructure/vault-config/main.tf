################################################################################
# vault_config — Local Terraform Workspace
#
# Configures Vault auth backends, secrets engines, policies, and roles.
# Runs locally with kubectl port-forward (not folded into the main root
# module) because the Vault provider needs direct API access to a
# cluster-internal service that a single root apply cannot reach without a
# live port-forward.
#
# All deploy-derived inputs come from the root module's outputs via
# data.terraform_remote_state.root (local backend → ../terraform.tfstate).
# That is the source of truth: e.g. ivia_issuer here is the SAME value the
# root uses to stamp iviaop's iss claim, so Vault's bound_issuer can never
# drift from the live issuer after an IVIA rebuild. The only external input
# is vault_token (a runtime secret, not in state).
#
# Usage:
#   kubectl port-forward svc/vault 8200:8200 -n vault &
#   terraform init
#   terraform apply -var="vault_token=<root-token>"
################################################################################

terraform {
  required_version = ">= 1.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Root module state (local backend). Exposes the deploy-derived inputs this
# workspace needs. Read-only — vault-config never writes to root state.
data "terraform_remote_state" "root" {
  backend = "local"
  config = {
    path = "../terraform.tfstate"
  }
}

locals {
  root = data.terraform_remote_state.root.outputs
}

provider "vault" {
  address = "http://127.0.0.1:8200"
  token   = var.vault_token
}

provider "aws" {
  region = local.root.region
}

module "vault_config" {
  source = "../modules/vault_config"

  region                             = local.root.region
  cluster_endpoint                   = local.root.cluster_endpoint
  cluster_certificate_authority_data = local.root.cluster_certificate_authority_data
  cluster_oidc_issuer                = local.root.cluster_oidc_issuer
  ivia_jwks_url                      = var.ivia_jwks_url
  ivia_issuer                        = local.root.ivia_issuer
  ivia_oidc_ca_pem                   = local.root.ivia_oidc_ca_pem
  rds_endpoint                       = local.root.rds_endpoint
  rds_master_username                = local.root.rds_master_username
  rds_master_user_secret_arn         = local.root.rds_master_user_secret_arn
  rds_db_name                        = var.rds_db_name
  bedrock_role_arn                   = local.root.bedrock_role_arn
  uc3_logs_role_arn                  = local.root.uc3_logs_role_arn
  tags                               = var.tags
}
