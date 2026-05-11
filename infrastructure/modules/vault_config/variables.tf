################################################################################
# vault_config Module — Variables
# Inputs wired from component.vault_config in deployments.tfdeploy.hcl
################################################################################

variable "cluster_endpoint" {
  description = "EKS API server endpoint — used by vault_kubernetes_auth_backend_config.kubernetes_host."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster CA certificate — decoded inline for vault_kubernetes_auth_backend_config.kubernetes_ca_cert."
  type        = string
  sensitive   = true
}

variable "cluster_oidc_issuer" {
  description = "EKS OIDC issuer URL (https://…) — sets the issuer field on the Kubernetes auth backend config (CONF-01)."
  type        = string
}

variable "ivia_oidc_discovery_url" {
  description = "IVIA (IBM Verify Identity Assertion) OIDC discovery URL — used as oidc_discovery_url for the jwt auth backend (CONF-02)."
  type        = string
}

variable "ivia_oidc_ca_pem" {
  description = "IVIA self-signed TLS certificate PEM. Vault needs this to trust the OIDC discovery endpoint (self-signed cert, not in system trust store)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "rds_endpoint" {
  description = "RDS endpoint in <address>:<port> form — matches rds module output 'endpoint' (no rds_ prefix). Used in the Vault PostgreSQL secrets engine connection_url."
  type        = string
}

variable "rds_master_username" {
  description = "RDS master username (vault_root). Vault PostgreSQL secrets engine connection_url user."
  type        = string
  default     = "vault_root"
}

variable "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN for the RDS master-user secret. Vault fetches the password via data.aws_secretsmanager_secret_version (same pattern as verify_access module)."
  type        = string
  sensitive   = true
}

variable "rds_db_name" {
  description = "Initial RDS database name (workshop). Vault PostgreSQL secrets engine creation statements target this database."
  type        = string
  default     = "workshop"
}

variable "bedrock_role_arn" {
  description = "ARN of the IAM role Vault assumes to issue scoped Bedrock STS credentials."
  type        = string
}

variable "region" {
  description = "AWS region — passed to the Vault AWS secrets engine backend configuration."
  type        = string
}

variable "tags" {
  description = "Tags applied to taggable AWS resources created by this module."
  type        = map(string)
  default     = {}
}
