################################################################################
# vault_config Local Workspace — Variables
#
# All deploy-derived inputs (region, cluster endpoint/CA/OIDC, RDS coordinates,
# IVIA issuer + OIDC CA cert, IAM role ARNs) are read from the root module's
# outputs via data.terraform_remote_state.root in main.tf — NOT hand-written
# here. That eliminates the stale-string class of bug (e.g. the JWT bound_issuer
# going stale after an IVIA rebuild changed the WRP ALB hostname).
#
# The ONLY genuinely external input is vault_token: the Vault root token is a
# runtime secret produced by `vault operator init`, not a Terraform-managed
# value, so it cannot come from state. The remaining vars are stable constants
# with defaults (never deploy-derived).
################################################################################

variable "vault_token" {
  description = "Vault root token from vault operator init. The one input that cannot come from root outputs (runtime secret, not in TF state). Used only for bootstrap; agents use Kubernetes auth."
  type        = string
  sensitive   = true
}

variable "ivia_jwks_url" {
  description = "IVIA JWKS URL (cluster-internal, stable Service DNS — never drifts on a rebuild). Vault fetches signing keys here. Service name is `iviaop` (Phase 7 rename — pre-Phase-7 was `isvaop`)."
  type        = string
  default     = "https://iviaop.verify-access.svc.cluster.local:8436/oauth2/jwks"
}

variable "rds_db_name" {
  description = "PostgreSQL database name (stable workshop constant; not deploy-derived)."
  type        = string
  default     = "workshop"
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
