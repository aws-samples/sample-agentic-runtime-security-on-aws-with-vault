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
  version = "= 1.23.0"

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

################################################################################
# Phase 07.8 Plan 03 — Let's Encrypt PRODUCTION ClusterIssuer (D-08)
#
# Issues browser-trusted certs via the ACME HTTP-01 challenge. The solver
# Ingress carries `alb.ingress.kubernetes.io/group.name = workshop-acme` to
# join the SAME shared ALB created by Plan 02 (IVIA WRP + banking-UI both
# carry group.name=workshop-acme group.order=10). The solver gets
# group.order="1" so the LBC evaluates the `/.well-known/acme-challenge/*`
# rule BEFORE the catch-all rules; without this the catch-all's HTTPS
# redirect annotation would 301 LE's HTTP-01 GET (LE does NOT follow
# redirects on challenge — RESEARCH Pitfall 1) and validation would fail.
#
# No staging ClusterIssuer (D-08 — production only). The Certificate CR that
# binds the resolved nip.io SANs to this issuer lands in Plan 04 (it requires
# the post-apply ALB hostname → IP resolution that Plan 04 owns).
#
# depends_on pins the cert-manager Helm release: per RESEARCH Pitfall 5 we
# need cert-manager.io/v1 CRDs registered before Terraform applies the CR.
################################################################################

resource "kubernetes_manifest" "letsencrypt_prod_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        # D-08 — Let's Encrypt PRODUCTION ACME endpoint (literal, hardcoded;
        # no staging knob, no attendee-facing override).
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.acme_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [
          {
            http01 = {
              ingress = {
                ingressClassName = "alb"
                ingressTemplate = {
                  metadata = {
                    annotations = {
                      "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
                      "alb.ingress.kubernetes.io/target-type"  = "ip"
                      "alb.ingress.kubernetes.io/group.name"   = "workshop-acme"
                      "alb.ingress.kubernetes.io/group.order"  = "1"
                      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\":80}]"
                      # Note: the HTTPS-redirect annotation is intentionally
                      # OMITTED here — RESEARCH Pitfall 1. LE's HTTP-01
                      # validator does NOT follow 301s; if the solver
                      # Ingress 301'd to HTTPS the challenge fails.
                    }
                  }
                }
              }
            }
          }
        ]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}
