################################################################################
# isva_config — Local Terraform Workspace
#
# Configures IVIA OIDC federation: OAuth clients, CIBA policy, RAR types,
# JWT signing. Runs locally with kubectl port-forward (not via HCP Terraform
# Stacks) because the restapi provider needs direct HTTPS access to the
# IVIA Config Service API.
#
# Usage:
#   kubectl port-forward svc/isvaop 8436:8436 -n verify-access &
#   terraform init
#   terraform apply
#
# Or use the wrapper script:
#   ../scripts/vault-configure.sh
################################################################################

terraform {
  required_version = ">= 1.0"

  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 1.19"
    }
  }
}

provider "restapi" {
  uri      = "https://127.0.0.1:8436"
  insecure = true

  headers = {
    "Content-Type" = "application/json"
  }

  username = var.ivia_admin_username
  password = var.ivia_admin_password
}

module "isva_config" {
  source = "../modules/isva_config"

  ivia_service_endpoint      = "isvaop.verify-access.svc.cluster.local"
  vault_config_jwt_auth_path = "jwt"
  ivia_admin_username        = var.ivia_admin_username
  ivia_admin_password        = var.ivia_admin_password
}
