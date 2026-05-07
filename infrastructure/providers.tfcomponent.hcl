################################################################################
# Required Providers and Provider Configurations
# Agentic Runtime Security Workshop — Phase 2 Foundation
# Reference: ~/git-repos/eks-terraform-stacks/infrastructure/providers.tfcomponent.hcl
#            adapted with workshop-specific provider pins (RESEARCH.md Pattern provider pins).
################################################################################

#-------------------------------------------------------------------------------
# Required Providers
#-------------------------------------------------------------------------------

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

  # Pinned EXACTLY to 2.2.0 — newer versions broken with AOSS auth (Pitfall B3).
  # Provider versions after 2.2.0 changed how SigV4 signing interacts with AOSS
  # endpoints; result is 403s during opensearch_index create. Required for
  # Bedrock KB vector index creation (AOSS will not auto-create the index — Pitfall B2).
  opensearch = {
    source  = "opensearch-project/opensearch"
    version = "= 2.2.0"
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

#-------------------------------------------------------------------------------
# Provider Configurations
#-------------------------------------------------------------------------------

# Primary AWS provider — uses OIDC authentication for HCP Terraform.
provider "aws" "main" {
  config {
    region = var.region

    assume_role_with_web_identity {
      role_arn           = var.role_arn
      web_identity_token = var.identity_token
    }
  }
}

# Kubernetes provider — token-based auth (required for Stacks remote execution).
provider "kubernetes" "main" {
  config {
    host                   = component.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(component.eks.cluster_certificate_authority_data)
    token                  = component.eks.cluster_token
  }
}

# Helm provider — must explicitly configure Kubernetes connection
# (Stacks doesn't inherit from kubernetes provider).
provider "helm" "main" {
  config {
    kubernetes {
      host                   = component.eks.cluster_endpoint
      cluster_ca_certificate = base64decode(component.eks.cluster_certificate_authority_data)
      token                  = component.eks.cluster_token
    }
  }
}

# OpenSearch provider — used by component.bedrock_kb_index to create the AOSS
# vector index. URL points at component.bedrock_kb_aoss.aoss_collection_endpoint
# (the AOSS collection is created in bedrock_kb_aoss). The split into two
# components avoids a provider→component→provider cycle: bedrock_kb_aoss does
# NOT use this provider, so there is no cycle.
provider "opensearch" "main" {
  config {
    url               = component.bedrock_kb_aoss.aoss_collection_endpoint
    healthcheck       = false
    aws_region        = var.region
    sign_aws_requests = true
  }
}

# TLS provider (required by EKS module).
provider "tls" "main" {
  config {}
}

# Null provider (required by EKS module + IAM eventual-consistency time_sleep bridges).
provider "null" "main" {
  config {}
}

# Cloudinit provider (required by EKS module).
provider "cloudinit" "main" {
  config {}
}

# Time provider (required by EKS, addons, bedrock_kb modules — IAM propagation sleeps).
provider "time" "main" {
  config {}
}

# Random provider (required by addons + rds modules for password / suffix generation).
provider "random" "main" {
  config {}
}
