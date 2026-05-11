################################################################################
# Vault Module — Variables
################################################################################

variable "region" {
  description = "AWS region where Vault and its KMS unseal key are deployed. Interpolated into Helm values (seal stanza) and IAM resources."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name. Used for the Pod Identity association and the KMS unseal IAM role name prefix."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API server endpoint. Passed through to kubernetes/helm provider configs in the Stacks component."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster. Used by kubernetes/helm provider authentication."
  type        = string
  sensitive   = true
}

variable "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider associated with the EKS cluster. Retained for forward compatibility; Vault itself uses Pod Identity (not IRSA)."
  type        = string
}

variable "audit_log_group_names" {
  description = "Map of audit-source name → CloudWatch log group name from the audit component. Keys: vault-audit, ivia-decision, agent-trace. Available for future fluent-bit configuration in this module."
  type        = map(string)
}

variable "node_security_group_id" {
  description = "EKS node security group ID. The vault_external NLB needs an inbound rule on port 8200 so HCP Terraform runners can reach Vault through the NLB."
  type        = string
}

variable "addons_ready" {
  description = "Consumed but unused — creates implicit Stacks ordering so Vault deploys after the AWS LB Controller webhook is serving."
  type        = any
  default     = null
}

variable "tags" {
  description = "Tags applied to all AWS resources created by this module."
  type        = map(string)
  default     = {}
}
