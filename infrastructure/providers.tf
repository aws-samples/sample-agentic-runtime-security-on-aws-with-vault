################################################################################
# Root Module — Provider Configuration
# Agentic Runtime Security Workshop
#
# HCP Terraform Workspace with local execution — state stored in HCP,
# plans and applies run on the attendee's machine with local AWS credentials.
#
# Kubernetes + Helm use exec-based auth via `aws eks get-token`.
#
# Canonical region contract:
#   var.region and var.kb_region are the only region references in .tf files.
################################################################################

terraform {
  # cloud {} block removed — using local state for this run.
  # To re-enable HCP Terraform, uncomment:
  # cloud {
  #   workspaces {
  #     name = "agentic-runtime-security"
  #   }
  # }

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
# depends_on defers data source evaluation until the cluster exists.
#-------------------------------------------------------------------------------

data "aws_eks_cluster" "this" {
  name       = var.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

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
