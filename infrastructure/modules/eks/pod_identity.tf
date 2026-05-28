################################################################################
# Pod Identity Role Builders for EKS Managed Addons
#
# Two managed addons declared in main.tf need IAM credentials:
#   - vpc-cni  → ENI / IP address management on nodes
#   - aws-ebs-csi-driver → EBS volume create/attach for PVCs
#
# These wrap terraform-aws-modules/eks-pod-identity/aws ~> 1.12 — a role-policy
# factory with flag-based attachment for known managed-addon policies. The
# `iam_role_arn` from each module is wired back into main.tf's
# `addons.<name>.pod_identity_association[].role_arn`.
#
# Pod Identity (NOT IRSA) is the AWS-blessed 2026 path:
#   - simpler than IRSA's per-role OIDC trust-policy maze
#   - one-step `aws-auth`-free attachment via the addon API itself
#   - works equally well for managed addons (here) and for Vault root identity
#     (Phase 3 — Vault root token retrieval from AWS Secrets Manager) and for
#     the addons module's external addons (cert-manager, external-dns, ALB
#     controller — Plan 02-06).
#
# Note: this module ships only the two Pod Identity targets needed by managed
# addons in this plan. External addons (cert-manager, external-dns, ALB
# controller) get their own Pod Identity associations in the Plan 02-06
# `addons` module. Agent pods themselves vend AWS credentials via Vault — Pod
# Identity is for infra components, not the agent identity story.
################################################################################

module "vpc_cni_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "= 1.12.1"

  name                      = "${var.cluster_name}-vpc-cni"
  attach_aws_vpc_cni_policy = true
  aws_vpc_cni_enable_ipv4   = true

  # NO `associations` block — the actual aws_eks_pod_identity_association is
  # created atomically by EKS itself via CreateAddon when main.tf passes
  # `pod_identity_association = [{ role_arn, service_account }]` to the
  # vpc-cni addon. Defining `associations` here too creates a duplicate
  # aws_eks_pod_identity_association that races CreateAddon and fails with
  # `409 ResourceInUseException: Association already exists` (seen in run
  # sdr-JQgSj7r9mV2ufm9M, 2026-05-07). This module now contributes only the
  # IAM role; main.tf's cluster_addons block contributes the association.

  tags = var.tags
}

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "= 1.12.1"

  name                      = "${var.cluster_name}-ebs-csi"
  attach_aws_ebs_csi_policy = true

  # See vpc_cni_pod_identity above — the association is owned by the EKS
  # aws-ebs-csi-driver addon's inline pod_identity_association, not here.

  tags = var.tags
}
