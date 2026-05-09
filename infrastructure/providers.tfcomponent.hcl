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

  # opensearch-project/opensearch is intentionally NOT declared. The AOSS
  # vector index for the Bedrock Knowledge Base is created via
  # aws_cloudformation_stack (AWS::OpenSearchServerless::Index) in
  # modules/bedrock_kb_index/index.tf — driven by the OIDC-authenticated
  # aws.main provider, no second credential chain to bridge. See the
  # comment at the top of bedrock_kb_index/index.tf for the rationale.

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

  # Vault provider — required by vault_config component (Wave 5).
  vault = {
    source  = "hashicorp/vault"
    version = "~> 4.0"
  }

  restapi = {
    source  = "Mastercard/restapi"
    version = "~> 1.19"
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

# KB AWS provider — same OIDC auth, different region (us-east-1).
# Nova 2 Multimodal Embeddings is us-east-1 only; Bedrock KB + AOSS
# must be co-located with the embedding model.
provider "aws" "kb" {
  config {
    region = var.kb_region

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

# Vault provider — Vault address is the in-cluster service DNS.
# vault_token is the root/initial token used only for bootstrap configuration;
# agents use short-lived tokens issued by the Kubernetes auth backend.
provider "vault" "main" {
  config {
    address = "http://vault.vault.svc.cluster.local:8200"
    token   = var.vault_token
  }
}

# TEMPORARILY REMOVED — clearing stale state (identity bug workaround)
# provider "restapi" "main" {
#   config {
#     uri      = "https://${component.ivia.ivia_service_endpoint}"
#     insecure = true
#     headers = {
#       "Content-Type" = "application/json"
#     }
#     username = var.ivia_admin_username
#     password = var.ivia_admin_password
#   }
# }
