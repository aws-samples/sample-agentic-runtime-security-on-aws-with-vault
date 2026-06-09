################################################################################
# Vault Module — Variables (IAM / KMS only)
################################################################################

variable "cluster_name" {
  description = "EKS cluster name. Used for the Pod Identity association and the KMS unseal IAM role name prefix."
  type        = string
}

variable "tags" {
  description = "Tags applied to all AWS resources created by this module."
  type        = map(string)
  default     = {}
}
