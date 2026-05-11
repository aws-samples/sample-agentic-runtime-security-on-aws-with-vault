################################################################################
# Vault Module — Main
#
# Deploys HashiCorp Vault 2.0.0 on EKS via Helm chart 0.32.0.
# Architecture:
#   - 3-node Raft HA in namespace "vault"
#   - Dedicated KMS key for auto-unseal (NOT the workshop CMK — different trust
#     domain; workshop CMK is for storage/logs/AOSS, unseal key for Vault process)
#   - Pod Identity IAM association (NOT IRSA) for Vault SA → KMS unseal role
#   - Audit to stdout (-log-format=json) for fluent-bit pickup; no PVC audit device
#
# Pitfall H1: helm provider MUST be ~> 2.17 (NOT 3.x — set{} syntax break).
# Pitfall V1: Vault service account is created by this module via Pod Identity;
#             set server.serviceAccount.create = false in Helm values.
# Pitfall V2: KMS unseal key must be separate from workshop CMK — Vault decrypt
#             calls would appear under the same CloudTrail key ARN as storage ops
#             if reused, breaking audit-correlation signal clarity.
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

################################################################################
# Dedicated KMS Unseal Key
# Separate from the workshop CMK (alias/workshop-data) for trust-domain clarity.
# Vault's unseal decrypt calls should be distinguishable from storage encrypt ops.
################################################################################

resource "aws_kms_key" "vault_unseal" {
  description             = "Vault auto-unseal key — workshop"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "VaultPodIdentityUnseal"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.vault_kms.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

################################################################################
# Data Sources
################################################################################

data "aws_caller_identity" "current" {}

################################################################################
# Pod Identity IAM Role for Vault KMS Unseal
# Uses EKS Pod Identity (NOT IRSA) — consistent with project pattern for
# workload IAM. Trust policy principal: pods.eks.amazonaws.com.
################################################################################

data "aws_iam_policy_document" "vault_kms_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "vault_kms_policy" {
  statement {
    sid    = "VaultUnseal"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.vault_unseal.arn]
  }
}

resource "aws_iam_role" "vault_kms" {
  name               = "${var.cluster_name}-vault-kms-unseal"
  assume_role_policy = data.aws_iam_policy_document.vault_kms_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "vault_kms" {
  name   = "vault-kms-unseal"
  role   = aws_iam_role.vault_kms.id
  policy = data.aws_iam_policy_document.vault_kms_policy.json
}

################################################################################
# EKS Pod Identity Association
# Binds namespace=vault, service_account=vault → vault_kms IAM role.
# Vault Helm chart uses SA name "vault" by default (serviceAccount.name).
################################################################################

resource "aws_eks_pod_identity_association" "vault" {
  cluster_name    = var.cluster_name
  namespace       = "vault"
  service_account = "vault"
  role_arn        = aws_iam_role.vault_kms.arn

  tags = var.tags
}

################################################################################
# Kubernetes Namespace
################################################################################

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

################################################################################
# Vault Service Account
# Created explicitly because the Helm chart's serviceAccount.create is false
# (Pitfall V1). Pod Identity does NOT create the SA — it only maps an existing
# SA to an IAM role. Without this resource, the StatefulSet fails:
#   "pods vault-0 is forbidden: serviceaccount vault not found"
################################################################################

resource "kubernetes_service_account" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "vault"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

################################################################################
# Vault Helm Release
# Chart: hashicorp/vault 0.32.0 (Vault server image 2.0.0)
# HA values rendered from vault-ha.yaml.tpl template.
#
# POST-DEPLOY MANUAL STEP — Two-phase bootstrap:
#   After this Helm release deploys the 3-node Raft cluster, Vault starts
#   sealed and uninitialized. KMS auto-unseal handles unsealing, but
#   initialization is a one-time manual operation:
#
#   1. kubectl exec -n vault vault-0 -- vault operator init -format=json
#      → Save root_token and recovery_keys (3-of-5 threshold).
#   2. Store vault_token (root token) in HCP variable set as sensitive+ephemeral.
#   3. Set enable_vault_config = true in deployments.tfdeploy.hcl.
#   4. Commit + push → next Stacks run deploys vault_config + downstream.
#
#   Recovery keys are needed only if KMS becomes unavailable. Store securely.
################################################################################

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.32.0"
  namespace  = kubernetes_namespace.vault.metadata[0].name

  values = [
    templatefile("${path.module}/values/vault-ha.yaml.tpl", {
      vault_image_tag = "2.0.0"
      kms_key_id      = aws_kms_key.vault_unseal.key_id
      region          = var.region
    })
  ]

  wait    = true
  timeout = 600

  depends_on = [
    aws_eks_pod_identity_association.vault,
    kubernetes_service_account.vault,
  ]
}

################################################################################
# External NLB — exposes Vault API to HCP Terraform runners
# HCP Stacks executes remotely and cannot resolve cluster-internal DNS.
# The vault_config component's Vault provider needs a routable endpoint.
# AWS LBC provisions an internet-facing NLB on port 8200.
################################################################################

resource "aws_security_group_rule" "vault_nlb_ingress" {
  type              = "ingress"
  from_port         = 8200
  to_port           = 8200
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = var.node_security_group_id
  description       = "Vault NLB ingress — HCP Terraform remote access"
}

resource "kubernetes_service" "vault_external" {
  metadata {
    name      = "vault-external"
    namespace = kubernetes_namespace.vault.metadata[0].name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
    }
    labels = {
      "app.kubernetes.io/name"       = "vault"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "app.kubernetes.io/name"     = "vault"
      "app.kubernetes.io/instance" = "vault"
      "component"                  = "server"
      "vault-active"               = "true"
    }

    port {
      name        = "http"
      port        = 8200
      target_port = 8200
      protocol    = "TCP"
    }
  }

  depends_on = [helm_release.vault]
}
