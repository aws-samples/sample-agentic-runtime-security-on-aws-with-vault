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

variable "ivia_jwks_url" {
  description = "IVIA JWKS URL — Vault fetches signing keys to validate IVIA-issued JWTs. Uses jwks_url instead of oidc_discovery_url because Vault's discovery validation fails with self-signed certs despite CA PEM."
  type        = string
}

variable "ivia_issuer" {
  description = "IVIA token issuer URL — issuer_id (immutable) on the OAuth resource server profile. Vault rejects tokens whose iss claim doesn't match, and Plan 05's entity aliases bind to this same issuer."
  type        = string
}

variable "ivia_oidc_ca_pem" {
  description = "IVIA self-signed TLS certificate PEM. Vault needs this to trust the JWKS endpoint (self-signed cert, not in system trust store)."
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

variable "uc3_logs_role_arn" {
  description = "ARN of the assumable IAM role Vault assumes to issue scoped CloudWatch Logs STS credentials (logs:PutLogEvents + logs:CreateLogStream on /workshop/ivia-decision only). Backs the aws/sts/uc3-logs-writer role for the UC3 agent's ivia_decisions anchor emission (OBJ-2, CONTEXT Delta-6)."
  type        = string
}

variable "region" {
  description = "AWS region — passed to the Vault AWS secrets engine backend configuration."
  type        = string
}

################################################################################
# OBO identity constants (Phase 9, Plan 05 — BLOCKER 1)
#
# These are STATIC WORKSHOP CONSTANTS, not computed values. Their single source
# of truth lives in the verify_access module (clients.yml.tftpl agent client_ids
# + base_layer.yaml.tftpl human usernames); Plan 05 threads them
# verify_access -> services -> vault-config into this module (no defaults here so
# an unbound value fails loud rather than silently binding the wrong identity).
#
# CRITICAL: the *_agent_identity values are the OAuth `act.sub` ACTOR claim
# values (the agents), NEVER a human sub. The *_human_sub(s) values are the human
# OAuth `sub` SUBJECT claim values. Wiring a human sub as an actor (or vice versa)
# breaks the OBO delegation check. UC1 is Kubernetes auth and presents no OAuth
# token to Vault, so it has deliberately NO agent-identity variable of its own
# (its registry identity binds via the Kubernetes-mount alias, not an act.sub).
################################################################################

variable "uc2_agent_identity" {
  description = "UC2 agent OAuth `act.sub` ACTOR claim value (the acting agent, e.g. 'agent-uc2'). Bound by the UC2 actor alias to the agent-uc2 entity. NOT a human sub. Source of truth: verify_access clients.yml.tftpl client_id agent-uc2."
  type        = string
}

variable "uc3_agent_identity" {
  description = "UC3 agent OAuth `act.sub` ACTOR claim value (the acting agent, e.g. 'uc3-actor') — the ACTOR that performs the RFC 8693 token exchange, NOT the human refund approver. Bound by the UC3 actor alias to the uc3-actor entity. Source of truth: verify_access clients.yml.tftpl client_id uc3-actor."
  type        = string
}

variable "uc3_human_sub" {
  description = "UC3 human OAuth `sub` SUBJECT claim value — the sole CIBA refund approver (e.g. 'jaime'). Registered as a human entity + subject alias (SUBJECT_HUMAN_MUST_BE_REGISTERED=yes). jaime is ALSO in uc2_human_subs — exactly ONE shared jaime entity spans UC2+UC3. Source of truth: verify_access base_layer.yaml.tftpl username jaime."
  type        = string
}

variable "uc2_human_subs" {
  description = "UC2 closed human OAuth `sub` set (e.g. ['oscar','jaime']). Each becomes a registered human entity + subject alias; no self-registration path exists. jaime overlaps uc3_human_sub and is deduped to ONE entity via toset(). Source of truth: verify_access base_layer.yaml.tftpl usernames oscar, jaime."
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to taggable AWS resources created by this module."
  type        = map(string)
  default     = {}
}
