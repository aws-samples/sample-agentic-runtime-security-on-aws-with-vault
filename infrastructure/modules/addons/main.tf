################################################################################
# EKS Blueprints Addons Module
#
# Wraps `aws-ia/eks-blueprints-addons ~> 1.0` to install the three external
# (non-managed) cluster addons that this workshop's CONTEXT.md heavy-baseline
# override pre-loads in Phase 2:
#
#   - cert-manager
#   - external-dns
#   - AWS Load Balancer Controller
#
# Front-loaded here so Phase 3 (Vault, IBM Verify Identity Access) and Phase 4+
# (Strands agents with ALB Ingress) can assume these exist.
#
# Pitfall H1: helm provider is pinned `~> 2.17`. Do NOT relax to 3.x — the
# `aws-ia/eks-blueprints-addons` module's helm_release shape is incompatible
# with helm provider 3.x as of pin time.
#
# Pod Identity vs IRSA: the pinned eks-blueprints-addons v1.x module installs
# these external addons via IRSA (uses `oidc_provider_arn`). CONTEXT's
# "Pod Identity for cluster addons" decision applies to MANAGED addons
# (vpc-cni, ebs-csi) which are owned by the `eks` module (Plan 02-03). External
# addons inherit module defaults — IRSA is acceptable here.
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17" # Pitfall H1 — DO NOT bump to 3.x
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn

  # ---------------------------------------------------------------------------
  # External addons (CONTEXT.md heavy-baseline override)
  # ---------------------------------------------------------------------------

  # cert-manager is deployed separately below (depends on LBC webhook ready).
  enable_cert_manager = false

  enable_external_dns = false

  # AWS Load Balancer Controller — provisions ALBs from Kubernetes Ingress.
  enable_aws_load_balancer_controller = true

  enable_karpenter = false
  enable_argocd    = false

  tags = var.tags
}

resource "time_sleep" "lbc_webhook_ready" {
  depends_on      = [module.eks_blueprints_addons]
  create_duration = "30s"
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.17.2"
  wait             = true
  timeout          = 300

  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [time_sleep.lbc_webhook_ready]
}
