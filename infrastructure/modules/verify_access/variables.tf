variable "region" {
  type        = string
  description = "AWS region."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Used for tagging only — provider config comes from root."
}

variable "icr_entitlement_key" {
  type        = string
  sensitive   = true
  description = "IBM Container Registry entitlement key. Used to build the 'dockerlogin' kubernetes.io/dockerconfigjson Secret in the 'verify-access' namespace."
}

variable "ivia_mmfa_push_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "VerifyPushCreds API Key for IBM Verify mobile-push (MMFA). Stored as the 'ivia-mmfa-push' Secret (data key imc_client_secret) in 'verify-access'; consumed by the AAC push_notification_providers config via !secret. Empty default keeps the secret absent until MMFA is enabled."
}

variable "node_security_group_id" {
  type        = string
  description = "EKS worker node shared security group ID. Used to add a cross-node TCP/636 (LDAPS) self-source ingress rule so pdconfig on iviaruntime can reach openldap pod across nodes."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to AWS resources created by this module (the SG rule)."
}

variable "tls_certificate_arn" {
  type        = string
  description = "Self-signed ACM cert ARN (wildcard *.<region>.elb.amazonaws.com) attached to the WRP ALB HTTPS:443 listener. provider.yml issuer/base_url are patched to the real ALB hostname at the root module post-apply."
}

