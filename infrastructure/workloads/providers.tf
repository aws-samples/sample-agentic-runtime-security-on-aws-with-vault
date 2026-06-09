################################################################################
# Tier-3 (workloads) — Provider Configuration
#
# Local state. The three end-user workload modules (uc1/uc2/uc3) deploy raw
# kubernetes_* manifests only — no aws/helm/kubectl providers needed. The
# kubernetes provider uses exec-based auth via `aws eks get-token`, with host /
# CA / cluster-name / region sourced from the tier-1 remote_state outputs
# (local.infra.*) — the same proven pattern tier 2 + vault-config use.
#
# The `null` provider backs the iviaop rollout-restart null_resource (its
# local-exec shells out to the aws + kubectl CLIs; those are binaries, NOT
# Terraform providers, so no aws/kubectl provider blocks are required here).
#
# No region string literal here (canonical region contract): the literal lives
# only in tier-1 terraform.tfvars and flows in via remote_state.
################################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", local.infra.region]
  }
}

provider "null" {}
