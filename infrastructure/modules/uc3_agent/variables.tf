################################################################################
# uc3_agent Module — Variables
#
# Inputs for the UC3 CIBA-privileged action agent Kubernetes resources:
# ServiceAccount, ConfigMap, Deployment, Service, and NetworkPolicies.
################################################################################

variable "namespace" {
  description = "Kubernetes namespace where the UC3 agent is deployed."
  type        = string
  default     = "banking-app"
}

variable "vault_endpoint" {
  description = "Vault cluster-internal URL reachable from the banking-app namespace (e.g. http://vault.vault.svc.cluster.local:8200)."
  type        = string
}

variable "vault_role" {
  description = "Vault Kubernetes auth role name bound to uc3-privileged-actor-sa."
  type        = string
  default     = "uc3"
}

variable "ivia_base_url" {
  description = "IVIA service base URL for CIBA token polling and token introspection (cluster-internal or ALB hostname)."
  type        = string
}

variable "ivia_client_id" {
  description = "IVIA OAuth client ID registered for the UC3 agent (CIBA-capable)."
  type        = string
  default     = "agent-uc3"
}

variable "ivia_client_secret" {
  description = "IVIA OAuth client secret for the agent-uc3 client. Workshop: stored in ConfigMap (acceptable for lab). Production: use a Kubernetes Secret."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ivia_external_url" {
  description = "IVIA ALB hostname URL reachable from the user's browser (for CIBA consent redirect). Distinct from ivia_base_url which is cluster-internal."
  type        = string
  default     = ""
}

variable "db_host" {
  description = "PostgreSQL host (RDS endpoint, no port suffix)."
  type        = string
}

variable "db_port" {
  description = "PostgreSQL TCP port."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "PostgreSQL database name on the RDS instance."
  type        = string
  default     = "workshop"
}

variable "uc3_agent_image" {
  description = "Container image URI for the UC3 privileged-action agent (ECR repository + tag)."
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock inference profile ID for the LLM used by the UC3 agent."
  type        = string
  default     = "us.amazon.nova-pro-v1:0"
}

variable "region" {
  description = "Primary AWS region where the EKS cluster runs."
  type        = string
}

variable "rds_cidr" {
  description = "CIDR block covering the RDS subnet group — used in uc3-allow-rds NetworkPolicy egress rule (TCP 5432)."
  type        = string
}

variable "vault_cidr" {
  description = "Optional CIDR block for Vault pods (in-cluster). When empty the NetworkPolicy uses port-only match (open to all destinations on 8200). Set to restrict further in production-like environments."
  type        = string
  default     = ""
}

variable "tags" {
  description = "AWS resource tags propagated for informational purposes (Kubernetes resources do not support AWS tags)."
  type        = map(string)
  default     = {}
}

variable "ivia_id_token_audience" {
  description = "IVIA OAuth client_id whose authorization-code flow minted the id_token forwarded by banking-ui to the uc3-agent /chat endpoint. Used as the 'aud' claim allowlist when verifying the bearer token. Default matches the banking-ui's OAuth client (var.ivia_client_id of the uc2_agent module)."
  type        = string
  default     = "agent-uc2"
}

variable "ivia_oidc_ca_pem" {
  description = "iviaop self-signed CA PEM the agent trusts on outbound IVIA TLS calls. Mounted at /etc/ssl/ivia/iviaop.pem; consumed by auth.py and agent.py via IVIA_CA_BUNDLE env var."
  type        = string
}

variable "ivia_runtime_url" {
  description = "AAC runtime (iviaruntime) cluster-internal HTTPS base URL (e.g. https://iviaruntime.verify-access.svc.cluster.local:9443). mmfa.py fires the MMFA push and reads admin SCIM transaction status here."
  type        = string
}

variable "ivia_scim_user" {
  description = "AAC runtime service user (easuser) for HTTP Basic on the admin SCIM read. Surfaced via ConfigMap IVIA_SCIM_USER (username is not a secret; the paired password is)."
  type        = string
}

variable "ivia_scim_password" {
  description = "Password for ivia_scim_user. Injected into the uc3-agent pod via a Kubernetes Secret (secretKeyRef IVIA_SCIM_PASSWORD) — never the ConfigMap."
  type        = string
  sensitive   = true
}

variable "ivia_runtime_ca_pem" {
  description = "iviaruntime self-signed serving cert (CN=isam, no SAN) the agent PINS for TLS to :9443. Mounted at /etc/ssl/ivia/iviaruntime.pem; consumed by mmfa.py via IVIA_RUNTIME_CA_BUNDLE (cert-pinning with check_hostname=False, never verify=False)."
  type        = string
}

variable "ivia_namespace" {
  description = "Namespace where IVIA runs (iviaop hosts the checkstatus rule that calls uc3-agent /api/ciba/status). Used as an additive ingress namespace_selector on uc3-allow-inbound."
  type        = string
  default     = "verify-access"
}
