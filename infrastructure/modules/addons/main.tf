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
      version = "~> 2.25"
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

  # cert-manager — TLS issuer for Vault, IVIA, and ALB-fronted services.
  # Default issuer ships with cert-manager; Vault PKI integration is deferred
  # to Phase 3+.
  enable_cert_manager = true

  # external-dns — automatic Route53 record management for ALB-fronted
  # Services. Required so attendee-visible URLs work without manual DNS.
  enable_external_dns = true

  # AWS Load Balancer Controller — provisions ALBs from Kubernetes Ingress.
  # replicaCount=2 keeps the mutating webhook reachable across pod restarts.
  # serviceMutatorWebhookConfig.failurePolicy=Ignore prevents the
  # `mservice.elbv2.k8s.aws` webhook from blocking Service mutations when LBC
  # pod endpoints aren't yet ready — critical during first-apply when
  # cert-manager / external-dns Services land in parallel with LBC install
  # (run sdr-W2pEpnLEeDCGMZ9M, 2026-05-07). Default upstream chart value is
  # `Fail`; `Ignore` is the workshop-safe choice — Service mutations are
  # convenience features (e.g. type=LoadBalancer auto-NLB), not security.
  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    wait = true
    set = [
      { name = "replicaCount", value = "2" },
      { name = "serviceMutatorWebhookConfig.failurePolicy", value = "Ignore" },
    ]
  }

  # ---------------------------------------------------------------------------
  # Explicitly disabled — out of scope for this workshop.
  # ---------------------------------------------------------------------------

  # Karpenter is OUT of scope (managed node group only — see project CLAUDE.md).
  enable_karpenter = false

  # ArgoCD is OUT of scope (Helm-direct or Stacks for app deployments — see
  # project CLAUDE.md).
  enable_argocd = false

  tags = var.tags
}
