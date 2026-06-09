################################################################################
# Vault Module — IAM / KMS (tier 1, core infrastructure)
#
# This module owns ONLY the foundational identity + key material for Vault:
#   - Dedicated KMS key for auto-unseal (NOT the workshop CMK — different trust
#     domain; workshop CMK is for storage/logs/AOSS, unseal key for Vault process)
#   - Pod Identity IAM role + association (NOT IRSA) for Vault SA → KMS unseal
#
# The Vault *server* (namespace, ServiceAccount, Helm release) lives in the
# tier-2 services root via modules/vault_server. The IAM role stays here in
# tier 1 because module.bedrock_kb_aoss names this role as a trusted principal
# in the KB-role trust policy (the Vault → Bedrock STS assume path), and AWS
# rejects a trust policy that names a principal that does not yet exist. So the
# role must be created in the same (earlier) tier as the KB role.
#
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
# The namespace + ServiceAccount themselves are created by modules/vault_server
# (tier 2). EKS Pod Identity associations are name-based mappings and do NOT
# require the SA/namespace to exist at creation time — the Pod Identity Agent
# resolves the association lazily when a vault pod requests credentials. So this
# association is created in tier 1 and the SA it points at appears in tier 2.
################################################################################

resource "aws_eks_pod_identity_association" "vault" {
  cluster_name    = var.cluster_name
  namespace       = "vault"
  service_account = "vault"
  role_arn        = aws_iam_role.vault_kms.arn

  tags = var.tags
}
