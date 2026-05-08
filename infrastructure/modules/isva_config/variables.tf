################################################################################
# isva_config Module — Variables
# Inputs wired from component.isva_config in components.tfcomponent.hcl
################################################################################

variable "ivia_service_endpoint" {
  description = "IVIA ClusterIP service DNS endpoint (host only, no scheme). Format: isvaop.verify-access.svc.cluster.local. The restapi provider constructs its URI as https://<endpoint>."
  type        = string
}

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

variable "vault_config_jwt_auth_path" {
  description = "JWT auth backend mount path from component.vault_config (value: 'jwt'). Stored for cross-reference documentation and downstream UC component inputs."
  type        = string
  default     = "jwt"
}
