################################################################################
# uc2_agent Module — Variables
#
# Inputs for the UC2 OAuth-personalized read-only banking app Kubernetes
# resources (namespace, ServiceAccounts, ConfigMaps, Deployments, Services,
# NetworkPolicies, ALB Ingress, DB seed).
################################################################################

variable "vault_addr" {
  description = "Vault cluster-internal address reachable from the banking-app namespace."
  type        = string
  default     = "http://vault.vault.svc.cluster.local:8200"
}

variable "vault_k8s_role" {
  description = "Vault Kubernetes auth role name bound to uc2-mcp-server-sa (MCP server workload identity)."
  type        = string
  default     = "uc2"
}

variable "vault_jwt_role" {
  description = "Vault JWT auth role name used by the MCP server for per-user token exchange."
  type        = string
  default     = "uc2-jwt"
}

variable "vault_db_role" {
  description = "Vault DB secrets engine role that vends SELECT-only ephemeral credentials on the banking schema."
  type        = string
  default     = "uc2-personal-readonly"
}

variable "rds_address" {
  description = "RDS endpoint host (no port suffix)."
  type        = string
}

variable "rds_port" {
  description = "RDS TCP port."
  type        = number
  default     = 5432
}

variable "rds_db_name" {
  description = "PostgreSQL database name on the RDS instance."
  type        = string
  default     = "workshop"
}

variable "rds_cidr" {
  description = "CIDR block of the VPC subnet group where RDS resides (used in banking-mcp-egress NetworkPolicy to RDS:5432)."
  type        = string
}

variable "knowledge_base_id" {
  description = "Amazon Bedrock Knowledge Base ID used by the UC2 agent for retrieval."
  type        = string
}

variable "region" {
  description = "Primary AWS region where the EKS cluster and Vault run."
  type        = string
}

variable "tls_certificate_arn" {
  description = "Self-signed ACM cert ARN (wildcard *.<region>.elb.amazonaws.com) attached to the banking-ui ALB HTTPS:443 listener. The redirect_uri (https://<own-alb-host>/callback) is derived from this module's own Ingress hostname."
  type        = string
}

variable "ivia_public_issuer" {
  description = "Public HTTPS OIDC issuer base URL for IVIAOP — the ivia-wrp (login) ALB hostname, e.g. https://k8s-verifyac-...elb.amazonaws.com. The UI builds IVIA_ISSUER = <this>/isvaop for discovery + authorize redirects."
  type        = string
}

variable "kb_region" {
  description = "AWS region where the Bedrock Knowledge Base is deployed (must match the KB embedding model region)."
  type        = string
}

variable "ui_image" {
  description = "Container image URI for the SvelteKit banking UI (ECR repository + tag)."
  type        = string
}

variable "agent_image" {
  description = "Container image URI for the Python Strands banking agent (ECR repository + tag)."
  type        = string
}

variable "mcp_image" {
  description = "Container image URI for the Node.js MCP server (ECR repository + tag)."
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock inference profile ID for the LLM used by the banking agent."
  type        = string
  default     = "us.amazon.nova-pro-v1:0"
}

variable "ivia_ingress_hostname" {
  description = "ALB hostname for the IVIA Ingress (internet-facing). Used to build the browser-facing IVIA issuer URL and the OAuth redirect URI."
  type        = string
}

variable "ivia_service_endpoint" {
  description = "IVIA cluster-internal service DNS (e.g. iviaop.verify-access.svc.cluster.local). Used for server-side CIBA status_update calls from the banking UI."
  type        = string
}

variable "ivia_client_id" {
  description = "IVIA OAuth client ID registered for the banking UI."
  type        = string
  default     = "agent-uc2"
}

variable "ivia_client_secret" {
  description = "IVIA OAuth client secret for the agent-uc2 client (ROPC token endpoint auth). Sourced from verify_access module output (random_password.client_secret). Workshop: stored in ConfigMap (acceptable for lab). Production: use a Kubernetes Secret."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ivia_oidc_ca_pem" {
  description = "iviaop self-signed CA PEM to trust on outbound Node.js fetches. Mounted as a K8s Secret and referenced via NODE_EXTRA_CA_CERTS at /etc/ssl/ivia/iviaop.pem."
  type        = string
}

variable "tags" {
  description = "AWS resource tags propagated to taggable resources (informational — Kubernetes resources do not support AWS tags)."
  type        = map(string)
  default     = {}
}
