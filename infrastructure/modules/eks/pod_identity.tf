################################################################################
# Pod Identity Role Builders for EKS Managed Addons
#
# Two managed addons declared in main.tf need IAM credentials:
#   - vpc-cni  → ENI / IP address management on nodes
#   - aws-ebs-csi-driver → EBS volume create/attach for PVCs
#
# These wrap terraform-aws-modules/eks-pod-identity/aws ~> 2.0 — a role-policy
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
  version = "~> 2.0"

  name                      = "${var.cluster_name}-vpc-cni"
  attach_aws_vpc_cni_policy = true
  aws_vpc_cni_enable_ipv4   = true

  associations = {
    main = {
      cluster_name    = var.cluster_name
      namespace       = "kube-system"
      service_account = "aws-node"
    }
  }

  tags = var.tags
}

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                      = "${var.cluster_name}-ebs-csi"
  attach_aws_ebs_csi_policy = true

  associations = {
    main = {
      cluster_name    = var.cluster_name
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }

  tags = var.tags
}
