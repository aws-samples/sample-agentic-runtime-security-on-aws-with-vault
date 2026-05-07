################################################################################
# EKS Blueprints Addons — Variables
################################################################################

variable "region" {
  description = "AWS region (canonical region from deployments.tfdeploy.hcl). Threaded through for parity with sibling modules; eks-blueprints-addons does not consume it directly but downstream tags + future region-aware addons will."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — wired from component.eks.cluster_name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint — wired from component.eks.cluster_endpoint."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version of the EKS cluster — wired from component.eks.cluster_version. The eks-blueprints-addons module gates addon chart versions on this value."
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA-bound addons (cert-manager, external-dns, AWS Load Balancer Controller) — wired from component.eks.oidc_provider_arn."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources created by the eks-blueprints-addons module."
  type        = map(string)
  default     = {}
}
