################################################################################
# isva_config Local Workspace — Variables
# Populated by ../scripts/vault-configure.sh or manual terraform.tfvars.
################################################################################

variable "ivia_admin_username" {
  description = "IVIA admin username for the Config Service REST API."
  type        = string
  default     = "admin"
}

variable "ivia_admin_password" {
  description = "IVIA admin password for the Config Service REST API."
  type        = string
  sensitive   = true
}
