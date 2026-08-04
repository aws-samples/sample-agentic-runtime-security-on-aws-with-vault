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

variable "acme_email" {
  description = "Let's Encrypt ACME account contact email — passed through from root var.acme_email. Optional (default empty); empty registers a no-contact account (LE turned off account emails and deleted stored addresses 2025-06-04). The cert-manager ClusterIssuer omits spec.acme.email entirely when this is empty."
  type        = string
  default     = ""
}

variable "workshop_tls_arn" {
  description = "Stable ACM certificate ARN bound to the workshop ALB HTTPS:443 listeners (minted by aws_acm_certificate.workshop_tls in the root module). Required input; no fallback. Phase 07.8 Plan 03 anchors two scopes on this ARN: (1) the ACM-sync CronJob's IAM policy is restricted to acm:ImportCertificate on THIS resource ONLY (STRIDE T-cronjob-iam-overprivilege mitigation, NOT wildcard); (2) the CronJob in-place upserts the Let's Encrypt cert content into THIS SAME ARN so the ALB listener annotation never changes across renewals (D-03 stable-ARN contract). The ARN itself is drift-protected by lifecycle.ignore_changes set on the source resource by Plan 02."
  type        = string
}
