################################################################################
# vault_config Local Workspace — Variables
# Populated by ../scripts/vault-configure.sh or manual terraform.tfvars.
################################################################################

variable "vault_token" {
  description = "Vault root token from vault operator init. Used only for bootstrap; agents use Kubernetes auth."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "AWS region where the EKS cluster and RDS run."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster CA certificate."
  type        = string
  sensitive   = true
}

variable "cluster_oidc_issuer" {
  description = "EKS OIDC issuer URL."
  type        = string
}

variable "ivia_jwks_url" {
  description = "IVIA JWKS URL (cluster-internal). Vault fetches signing keys from this endpoint."
  type        = string
  default     = "https://isvaop.verify-access.svc.cluster.local:8436/oauth2/jwks"
}

variable "ivia_issuer" {
  description = "IVIA token issuer URL (external ALB). Vault validates the iss claim against this. Must match IVIA definition.token_settings.issuer."
  type        = string
}

variable "ivia_oidc_ca_pem" {
  description = "IVIA self-signed TLS certificate PEM. Vault needs this to trust the JWKS endpoint."
  type        = string
  sensitive   = true
}

variable "rds_endpoint" {
  description = "RDS endpoint in host:port form."
  type        = string
}

variable "rds_master_username" {
  description = "RDS master username."
  type        = string
  default     = "vault_root"
}

variable "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN for the RDS master-user secret."
  type        = string
  sensitive   = true
}

variable "rds_db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "workshop"
}

variable "bedrock_role_arn" {
  description = "IAM role ARN Vault assumes for scoped Bedrock STS credentials."
  type        = string
}

variable "tags" {
  description = "Tags applied to taggable AWS resources."
  type        = map(string)
  default = {
    Environment = "workshop"
    Workshop    = "agentic-runtime-security"
    ManagedBy   = "terraform-local"
  }
}
