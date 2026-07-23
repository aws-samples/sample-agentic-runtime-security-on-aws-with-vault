################################################################################
# Vault Server Module — Variables (tier 2)
################################################################################

variable "region" {
  description = "AWS region. Rendered into the Vault KMS seal stanza so the awskms seal calls the correct regional endpoint."
  type        = string
}

variable "kms_key_id" {
  description = "Key ID of the dedicated Vault unseal KMS key. Created in tier 1 (modules/vault) and read here via the tier-1 remote_state output vault_unseal_kms_key_id."
  type        = string
}

variable "tags" {
  description = "Tags applied to taggable resources created by this module."
  type        = map(string)
  default     = {}
}

variable "vault_enterprise_license" {
  description = "Vault Enterprise license (.hclic contents) autoloaded via a K8s secret + Helm server.enterpriseLicense. Per-attendee deploy input — NEVER a default; identity/secret material must never have a default."
  type        = string
  sensitive   = true
}
