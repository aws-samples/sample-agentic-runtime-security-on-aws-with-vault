################################################################################
# Tier-2 (services) — Provider Configuration
#
# Local state. Kubernetes + Helm use exec-based auth via `aws eks get-token`,
# with host / CA / cluster-name / region sourced from the tier-1 remote_state
# outputs (local.infra.*) — the same proven pattern vault-config uses for its
# aws provider. No region string literal here (canonical region contract): the
# literal lives only in tier-1 terraform.tfvars and flows in via remote_state.
################################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Pinned to 2.17 — v3.x broke set { } block syntax (Pitfall H1).
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = local.infra.region
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

provider "helm" {
  kubernetes {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", local.infra.region]
    }
  }
}

provider "random" {}
provider "tls" {}
provider "time" {}
provider "archive" {}
