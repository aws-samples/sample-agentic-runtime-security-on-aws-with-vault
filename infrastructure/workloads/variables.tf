################################################################################
# Tier-3 (workloads) — Input Variables
#
# Only the inputs NOT available from tier-1/tier-2 state live here: the ECR
# image URIs (built by build-images.sh between the tier-1 and tier-2 applies),
# the Bedrock model id, and the .acme-state path. region / cluster wiring / RDS
# / KB / ACM cert / tags come from tier-1 state; Vault + IVIA wiring comes from
# tier-2 state.
################################################################################

variable "uc1_agent_image" {
  type        = string
  description = "ECR image URI for the UC1 agent container. Built from infrastructure/modules/uc1_agent/agent/Dockerfile."
}

variable "banking_app_ui_image" {
  type        = string
  description = "ECR image URI for the banking app UI container (tag: ui)."
}

variable "banking_app_agent_image" {
  type        = string
  description = "ECR image URI for the banking app agent container (tag: agent)."
}

variable "banking_app_mcp_image" {
  type        = string
  description = "ECR image URI for the banking app MCP server container (tag: mcp)."
}

variable "uc3_agent_image" {
  type        = string
  description = "ECR image URI for the UC3 privileged-action agent container. Built from applications/uc3-agent/Dockerfile."
}

variable "bedrock_model_id" {
  type        = string
  description = "Bedrock model ID for agent LLM calls. Uses cross-region inference profile."
  default     = "us.amazon.nova-pro-v1:0"
}

variable "deploy_id_state_path" {
  type        = string
  default     = "../.acme-state"
  description = "Path (resolved from infrastructure/workloads/) to the local .acme-state file written by deploy-workshop.sh ACME step. Lives at infrastructure/.acme-state, so the default reaches up one level. Read here for NIP_FQDN_BANKING (banking-ui LE-trusted FQDN). Gitignored."
}
