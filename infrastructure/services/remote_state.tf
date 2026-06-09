################################################################################
# Tier-2 (services) — Tier-1 remote state
#
# Reads the tier-1 (infrastructure/) root state via the local backend. This is
# the SAME pattern vault-config uses (infrastructure/vault-config/main.tf). The
# read is the structural ordering edge: tier 2 cannot apply until tier 1 has
# written ../terraform.tfstate. deploy-workshop.sh enforces that order.
################################################################################

data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "../terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}
