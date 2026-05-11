################################################################################
# vault_config — Local Terraform Workspace
#
# Configures Vault auth backends, secrets engines, policies, and roles.
# Runs locally with kubectl port-forward (not via HCP Terraform Stacks)
# because the Vault provider needs direct API access and HCP runners
# cannot reach cluster-internal services.
#
# Usage:
#   kubectl port-forward svc/vault 8200:8200 -n vault &
#   terraform init
#   terraform apply
#
# Or use the wrapper script:
#   ../scripts/vault-configure.sh
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

provider "vault" {
  address = "http://127.0.0.1:8200"
  token   = var.vault_token
}

provider "aws" {
  region = var.region
}

module "vault_config" {
  source = "../modules/vault_config"

  region                             = var.region
  cluster_endpoint                   = var.cluster_endpoint
  cluster_certificate_authority_data = var.cluster_certificate_authority_data
  cluster_oidc_issuer                = var.cluster_oidc_issuer
  ivia_oidc_discovery_url            = var.ivia_oidc_discovery_url
  ivia_oidc_ca_pem                   = var.ivia_oidc_ca_pem
  rds_endpoint                       = var.rds_endpoint
  rds_master_username                = var.rds_master_username
  rds_master_user_secret_arn         = var.rds_master_user_secret_arn
  rds_db_name                        = var.rds_db_name
  bedrock_role_arn                   = var.bedrock_role_arn
  tags                               = var.tags
}
