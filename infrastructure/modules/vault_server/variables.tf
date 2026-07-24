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
  description = "Vault Enterprise license (.hclic contents) autoloaded via a K8s secret + Helm server.enterpriseLicense. Sourced by deploy-workshop.sh from the shared workshop license committed at infrastructure/modules/vault_server/vault-ent.hclic (attendees cannot self-serve a Vault Enterprise license). The Terraform variable itself has NO default — the value is always passed in from the file at provisioning time."
  type        = string
  sensitive   = true
}
