################################################################################
# Root Module — Provider Configuration
# Agentic Runtime Security Workshop
#
# HCP Terraform Workspace with remote execution + dynamic AWS credentials.
# HCP injects OIDC token via TFC_AWS_PROVIDER_AUTH + TFC_AWS_RUN_ROLE_ARN
# env vars — the AWS provider block stays minimal (region only).
#
# For the aws.kb alias (us-east-1), we use tfc_aws_dynamic_credentials to
# route through the same OIDC credential with a different region.
#
# Kubernetes + Helm use token-based auth via data.aws_eks_cluster_auth
# (no exec — remote workers don't have the aws CLI).
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
# Primary AWS provider — HCP dynamic credentials handle auth transparently.
# TFC_AWS_PROVIDER_AUTH=true + TFC_AWS_RUN_ROLE_ARN set as workspace env vars.
#-------------------------------------------------------------------------------

provider "aws" {
  region = var.region
}

#-------------------------------------------------------------------------------
# KB AWS provider — same OIDC credential, different region.
# Nova 2 Multimodal Embeddings is us-east-1 only; Bedrock KB + AOSS
# must be co-located with the embedding model.
#-------------------------------------------------------------------------------

provider "aws" {
  alias  = "kb"
  region = var.kb_region
}

#-------------------------------------------------------------------------------
# Kubernetes + Helm — token-based auth via data.aws_eks_cluster_auth.
# No exec blocks — HCP remote workers don't have the aws CLI.
# depends_on defers data source evaluation until the cluster exists.
#-------------------------------------------------------------------------------

data "aws_eks_cluster" "this" {
  name       = var.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name       = var.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
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
