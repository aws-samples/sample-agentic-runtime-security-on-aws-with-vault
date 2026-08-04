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
    # gavinbunney/kubectl — lazy-connects at apply time. Used for the
    # cert-manager ClusterIssuer below (a CRD that does not exist at plan
    # time on a from-scratch deploy, so hashicorp/kubernetes
    # `kubernetes_manifest` fails with "no client config" — provider #1391).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
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

# `kubectl_manifest` (gavinbunney/kubectl) — NOT hashicorp/kubernetes's
# `kubernetes_manifest`. The latter dry-runs against the live cluster API at
# PLAN time, which fails with "Failed to construct REST client: no client
# config" on a from-scratch deploy where the cluster hasn't been created yet
# (hashicorp/terraform-provider-kubernetes #1391). `kubectl_manifest`
# lazy-connects at APPLY time, which is correct for any CRD whose CRD itself
# is installed earlier in the same apply graph (cert-manager Helm chart above).
resource "kubectl_manifest" "letsencrypt_prod_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      # The ACME `email` key is included ONLY when var.acme_email is non-empty.
      # An empty value registers a no-contact account: Let's Encrypt turned off
      # expiration-notice emails and DELETED all stored ACME account emails on
      # 2025-06-04, and accepts (does not error on) no-contact accounts.
      # Rendering `email: ""` is NOT the same as omitting the key, so merge it
      # in conditionally rather than always setting it.
      acme = merge(
        {
        # D-08 — Let's Encrypt PRODUCTION ACME endpoint (literal, hardcoded;
        # no staging knob, no attendee-facing override).
        server = "https://acme-v02.api.letsencrypt.org/directory"
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
        },
        var.acme_email != "" ? { email = var.acme_email } : {}
      )
    }
  })

  # ClusterIssuer has no meaningful rollout; skip provider's default wait.
  wait_for_rollout = false

  depends_on = [helm_release.cert_manager]
}

################################################################################
# Phase 07.8 Plan 03 — ACM-sync CronJob (every 6h) + ServiceAccount + Pod
# Identity + scoped IAM
#
# Architecture: cert-manager native renewal lives in the Certificate CR (added
# by Plan 04, sets renewBefore: 720h — 30d before LE's 90d expiry). When
# cert-manager rotates the cert it rewrites the K8s Secret
# `workshop-le-tls-secret` IN PLACE. The CronJob below runs every 6h, mounts
# that Secret, and calls `aws acm import-certificate --certificate-arn
# $STABLE_ARN ...` to upsert the new cert content INTO THE SAME ACM ARN. The
# ALB listener annotation never changes. (D-03 stable-ARN contract; D-09
# cert-manager owns renewal — this CronJob is the SYNC mechanism, NOT the
# renewer.)
#
# Pre-Plan-04 tolerance: at the time this plan applies, Plan 04's Certificate
# CR has not shipped, so the K8s Secret `workshop-le-tls-secret` does not
# exist yet. The Secret volume below is marked `optional = true` and the
# CronJob container has an early-return guard (`[ ! -f $CERT_PATH ] && exit
# 0`) so the first 6h cycle silently no-ops until Plan 04 lands.
#
# IAM scope (T-cronjob-iam-overprivilege mitigation): the inline policy
# allows acm:ImportCertificate + acm:DescribeCertificate on var.workshop_tls_arn
# ONLY — not the wildcard form. Pod Identity binds the cert-manager
# namespace's `acm-sync` ServiceAccount to this role, so credentials only
# reach pods running with that exact SA in that exact namespace.
################################################################################

# ServiceAccount used by the CronJob — Pod Identity attaches IAM creds at
# pod-start. cert-manager namespace is created by the Helm release above.
resource "kubernetes_service_account" "acm_sync" {
  metadata {
    name      = "acm-sync"
    namespace = "cert-manager"
    labels = {
      "app.kubernetes.io/name"       = "acm-sync"
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "workshop-tls"
    }
  }

  automount_service_account_token = true

  depends_on = [helm_release.cert_manager]
}

# Trust policy: pods.eks.amazonaws.com Service principal (Pod Identity
# pattern, NOT IRSA). Mirrors vault/main.tf:96-104 + observability/main.tf:51-61.
data "aws_iam_policy_document" "acm_sync_trust" {
  statement {
    sid     = "AllowEKSPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# Inline policy: SCOPED to the single workshop ACM ARN. Resource is the
# exact var.workshop_tls_arn — NOT `*`, NOT a wildcard ARN pattern.
data "aws_iam_policy_document" "acm_sync_import" {
  statement {
    sid    = "WorkshopACMImport"
    effect = "Allow"
    actions = [
      "acm:ImportCertificate",
      "acm:DescribeCertificate",
    ]
    resources = [var.workshop_tls_arn]
  }
}

resource "aws_iam_role" "acm_sync" {
  name               = "${var.cluster_name}-acm-sync"
  assume_role_policy = data.aws_iam_policy_document.acm_sync_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "acm_sync" {
  name   = "acm-import-workshop"
  role   = aws_iam_role.acm_sync.id
  policy = data.aws_iam_policy_document.acm_sync_import.json
}

resource "aws_eks_pod_identity_association" "acm_sync" {
  cluster_name    = var.cluster_name
  namespace       = "cert-manager"
  service_account = "acm-sync"
  role_arn        = aws_iam_role.acm_sync.arn

  tags = var.tags

  depends_on = [kubernetes_service_account.acm_sync]
}

# CronJob: every 6h, reads the Plan-04 K8s Secret `workshop-le-tls-secret`
# from /tls, calls `aws acm import-certificate` against the stable ARN. The
# Secret volume is `optional = true` so cycles BEFORE Plan 04 lands the
# Certificate CR are silent no-ops (the guard in args exits 0 when the cert
# file is absent).
resource "kubernetes_cron_job_v1" "acm_sync" {
  metadata {
    name      = "acm-sync"
    namespace = "cert-manager"
    labels = {
      "app.kubernetes.io/name"       = "acm-sync"
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "workshop-tls"
    }
  }

  spec {
    schedule                      = "0 */6 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = { "app.kubernetes.io/name" = "acm-sync" }
      }

      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 3600

        template {
          metadata {
            labels = { "app.kubernetes.io/name" = "acm-sync" }
          }

          spec {
            service_account_name = kubernetes_service_account.acm_sync.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name    = "acm-sync"
              image   = "public.ecr.aws/aws-cli/aws-cli:latest"
              command = ["/bin/sh", "-c"]
              args = [<<-EOT
                set -eu
                CERT_PATH=/tls/tls.crt
                KEY_PATH=/tls/tls.key
                CHAIN_PATH=/tls/ca.crt
                if [ ! -f "$CERT_PATH" ]; then
                  echo "K8s Secret workshop-le-tls-secret not yet populated by cert-manager Certificate CR (Plan 04 not landed). Exit 0 — CronJob will retry next 6h cycle."
                  exit 0
                fi
                if [ ! -f "$CHAIN_PATH" ]; then
                  echo "ca.crt absent — Certificate CR with intermediate chain has not yet been issued. Exit 0; retry next cycle."
                  exit 0
                fi
                echo "Importing LE cert content into stable ACM ARN $STABLE_ARN (region $REGION)"
                aws acm import-certificate \
                  --certificate-arn "$STABLE_ARN" \
                  --certificate     "fileb://$CERT_PATH" \
                  --private-key     "fileb://$KEY_PATH" \
                  --certificate-chain "fileb://$CHAIN_PATH" \
                  --region "$REGION"
                echo "import-certificate completed"
              EOT
              ]

              env {
                name  = "STABLE_ARN"
                value = var.workshop_tls_arn
              }
              env {
                name  = "REGION"
                value = var.region
              }

              volume_mount {
                name       = "tls"
                mount_path = "/tls"
                read_only  = true
              }
            }

            volume {
              name = "tls"
              secret {
                # Plan 04's Certificate CR creates this Secret. `optional = true`
                # lets the CronJob mount no-op until then.
                secret_name = "workshop-le-tls-secret"
                optional    = true
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.cert_manager,
    aws_eks_pod_identity_association.acm_sync,
  ]
}
