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

# Phase 07.8 Plan 05 — nip.io FQDN propagation for IVIA WRP MMFA endpoints.
# The root module reads .acme-state (written by Plan 04's deploy-workshop.sh
# ACME step) and parses the NIP_FQDN_WRP= line into this variable. When empty
# (first-deploy bootstrap, before .acme-state exists) the verify_access module
# falls back to the Ingress-status hostname so the autoconf base_layer always
# has a resolvable host. After Plan 04's second apply, this carries the
# wrp.<deploy_id>.<alb_ip_dashed>.nip.io FQDN that IBM Verify validates against
# the LE-trusted chain during MMFA enrollment.
variable "nip_io_wrp_host" {
  type        = string
  default     = ""
  description = "nip.io FQDN for IVIA WRP, sourced from .acme-state by the root module. Empty triggers fallback to the Ingress-status hostname for first-deploy bootstrap."
}

