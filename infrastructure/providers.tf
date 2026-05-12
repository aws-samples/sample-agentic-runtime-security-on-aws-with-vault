################################################################################
# Root Module — Provider Configuration
# Agentic Runtime Security Workshop
# Migrated from Stacks providers.tfcomponent.hcl → standard Terraform providers.tf
# HCP Terraform Workspace (not Stacks) drives the remote backend automatically.
#
# Canonical region contract:
#   - var.region and var.kb_region are the only region references in .tf files.
#   - String literals "us-west-2" / "us-east-1" appear ONLY in terraform.tfvars.
################################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Pinned to 2.17 — v3.x broke set { } block syntax (Pitfall H1).
    # Helm 3.0.0 (released 2025-11) migrated to Terraform Plugin Framework and
    # silently changed the helm_release schema: `set { name = "x"; value = "y" }`
    # blocks became list-of-objects. Existing v2 config is silently invalid in v3
    # — old syntax compiles to wrong values and state migration recreates releases.
    # 2.17 is the final 2.x release. DO NOT auto-upgrade.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }

    # opensearch-project/opensearch is intentionally NOT declared. The AOSS
    # vector index for the Bedrock Knowledge Base is created via
    # aws_cloudformation_stack (AWS::OpenSearchServerless::Index) in
    # modules/bedrock_kb_index/index.tf — driven by the aws provider,
    # no second credential chain to bridge.
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
# Primary AWS provider — attendee local credentials (env vars / ~/.aws/credentials).
# No assume_role_with_web_identity — that was Stacks OIDC-specific (removed per
# RESEARCH Open Question 1 recommendation: agent runs locally with attendee creds).
#-------------------------------------------------------------------------------

provider "aws" {
  region = var.region
}

#-------------------------------------------------------------------------------
# KB AWS provider — same credential chain, different region.
# Nova 2 Multimodal Embeddings is us-east-1 only; Bedrock KB + AOSS
# must be co-located with the embedding model. (Pitfall 5 preservation.)
#-------------------------------------------------------------------------------

provider "aws" {
  alias  = "kb"
  region = var.kb_region
}

#-------------------------------------------------------------------------------
# Chicken-and-egg pattern for Kubernetes + Helm providers.
# The EKS cluster endpoint is not known until module.eks runs, so we use
# data sources with depends_on = [module.eks] to defer provider resolution.
# exec-based token preferred (more reliable on long applies; the tfc-agent
# and attendee machines both have the aws CLI available).
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
# Remaining providers — no configuration needed beyond defaults.
#-------------------------------------------------------------------------------

provider "tls" {}
provider "null" {}
provider "cloudinit" {}
provider "time" {}
provider "random" {}
