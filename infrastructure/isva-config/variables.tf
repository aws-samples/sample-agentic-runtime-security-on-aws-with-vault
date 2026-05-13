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

variable "uc2_redirect_uri" {
  description = "OAuth redirect URI for UC2 banking app. Set to http://<banking-ui-alb>/callback after deployment."
  type        = string
  default     = "http://localhost:5173/callback"
}
