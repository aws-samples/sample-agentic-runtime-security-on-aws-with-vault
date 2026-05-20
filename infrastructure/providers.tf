################################################################################
# Root Module — Provider Configuration
# Agentic Runtime Security Workshop
#
# Local state. Kubernetes + Helm use exec-based auth via `aws eks get-token`.
#
# Canonical region contract:
#   var.region and var.kb_region are the only region references in .tf files.
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
      version = "~> 2.25"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }

    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.0"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

#-------------------------------------------------------------------------------
# AWS provider — uses local credentials (AWS_PROFILE, env vars, or SSO).
#-------------------------------------------------------------------------------

provider "aws" {
  region = var.region
}

#-------------------------------------------------------------------------------
# KB AWS provider — same credentials, different region.
# Nova 2 Multimodal Embeddings is us-east-1 only; Bedrock KB + AOSS
# must be co-located with the embedding model.
#-------------------------------------------------------------------------------

provider "aws" {
  alias  = "kb"
  region = var.kb_region
}

#-------------------------------------------------------------------------------
# Kubernetes + Helm — exec-based auth via aws eks get-token.
# Use module.eks outputs directly (NOT a data source with depends_on). Data
# sources with depends_on become deferred at plan time, leaving provider
# configs with null host/CA and producing "Kubernetes cluster unreachable:
# no configuration has been provided" errors on helm_release refresh. The
# module.eks output reference establishes provider→cluster dependency
# naturally without the deferred-evaluation pitfall.
# Refs: hashicorp/terraform-provider-helm#681, terraform-provider-kubernetes#1391
#-------------------------------------------------------------------------------

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

#-------------------------------------------------------------------------------
# Remaining providers
#-------------------------------------------------------------------------------

provider "tls" {}
provider "null" {}
provider "cloudinit" {}
provider "time" {}
provider "random" {}
