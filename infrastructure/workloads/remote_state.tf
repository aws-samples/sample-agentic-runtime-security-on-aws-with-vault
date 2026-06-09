################################################################################
# Tier-3 (workloads) — Tier-1 + Tier-2 remote state
#
# Reads BOTH upstream roots via the local backend:
#   - tier 1 (infrastructure/)          → ../terraform.tfstate          (local.infra)
#   - tier 2 (infrastructure/services/) → ../services/terraform.tfstate (local.services)
#
# These two reads ARE the structural ordering edges: tier 3 cannot apply until
# tier 1 AND tier 2 have each written their terraform.tfstate. The end-user
# workloads (uc1/uc2/uc3) need the cluster + RDS + KB + ACM cert from tier 1 and
# the Vault server + IVIA OIDC provider from tier 2 to already exist.
# deploy-workshop.sh enforces that apply order.
################################################################################

data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "../terraform.tfstate"
  }
}

data "terraform_remote_state" "services" {
  backend = "local"
  config = {
    path = "../services/terraform.tfstate"
  }
}

locals {
  infra    = data.terraform_remote_state.infra.outputs
  services = data.terraform_remote_state.services.outputs
}
