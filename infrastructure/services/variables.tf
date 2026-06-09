################################################################################
# Tier-2 (services) — Input Variables
#
# Only the inputs that are NOT available from tier-1 state live here:
# IVIA registry credentials (secrets, never in tier-1 state) and the
# .acme-state path. region / cluster_name / node_security_group_id /
# tls_certificate_arn / vault KMS key id / tags all come from remote_state.
################################################################################

variable "icr_entitlement_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "IBM Container Registry entitlement key for pulling IVIA images (icr.io/ivia/ivia-oidc-provider). Supplied via gitignored terraform.tfvars."
}

variable "ivia_mmfa_push_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "VerifyPushCreds API Key for IBM Verify mobile-push (MMFA). For ISVA 10.0.3+ the API Key IS the push provider Client Secret. Stored as the 'ivia-mmfa-push' Secret in 'verify-access'. Leave empty until MMFA is enabled."
}

variable "deploy_id_state_path" {
  type        = string
  default     = "../.acme-state"
  description = "Path (resolved from infrastructure/services/) to the local .acme-state file written by deploy-workshop.sh ACME step. Lives at infrastructure/.acme-state, so the default reaches up one level. Gitignored."
}
