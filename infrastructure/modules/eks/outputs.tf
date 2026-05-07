################################################################################
# EKS Module Outputs
################################################################################

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL for the cluster (kept for backwards compatibility — Pod Identity is preferred over IRSA in this workshop)"
  value       = module.eks.cluster_oidc_issuer_url
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster (consumed by kubernetes/helm provider configs)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS managed node group"
  value       = module.eks.node_security_group_id
}

output "cluster_token" {
  description = "Short-lived authentication token for the EKS cluster (consumed by kubernetes/helm provider configs in Stacks remote execution)"
  value       = data.aws_eks_cluster_auth.this.token
  sensitive   = true
}

output "kubectl_config_command" {
  description = "Run this to populate ~/.kube/config (INFR-05 — workshop attendee one-liner)"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias workshop"
}

output "cluster_version" {
  description = "Kubernetes minor version of the EKS control plane (consumed by addons component for Helm chart compatibility)"
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider associated with the EKS cluster (consumed by addons component for IRSA-style role trust where Pod Identity isn't applicable)"
  value       = module.eks.oidc_provider_arn
}
