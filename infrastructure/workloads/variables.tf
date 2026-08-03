################################################################################
# Tier-3 (workloads) — Input Variables
#
# image_source selects the container image consume path for this tier:
#   ecr (default): the 5 image vars below carry the ECR URIs stamped by
#                  bootstrap.sh; imagePullPolicy Always.
#   ghcr (opt-out): URIs derived from var.ghcr_registry_base in locals;
#                   imagePullPolicy IfNotPresent; the 5 image vars below are
#                   ignored (default "").
#
# region / cluster wiring / RDS / KB / ACM cert come from tier-1 state; Vault +
# IVIA wiring comes from tier-2 state.
################################################################################

#-------------------------------------------------------------------------------
# Image Source Toggle
#-------------------------------------------------------------------------------

variable "image_source" {
  type        = string
  description = "Image source mode: 'ecr' (default — build the five Use Case images locally and push them to the account's private ECR; requires a container runtime) or 'ghcr' (opt-out — pull pre-built public images from GHCR, no build)."
  default     = "ecr"

  validation {
    condition     = contains(["ghcr", "ecr"], var.image_source)
    error_message = "image_source must be 'ghcr' or 'ecr'."
  }
}

variable "ghcr_registry_base" {
  type        = string
  description = "Base registry/namespace for pre-built GHCR images (ghcr mode), e.g. ghcr.io/<githubusername>. Bring your own — there is no default namespace; the ghcr opt-out requires you to publish the five workshop images to your own GHCR first (see the repo README). The five workshop image URIs are derived from this base in locals; a fork repoints both publish (publish-images.sh --registry-base) and consume (this var) with a single setting. Ignored in ecr mode."
  default     = ""
}

#-------------------------------------------------------------------------------
# Per-image override vars (ecr mode only)
# In ghcr mode these default to "" and are ignored; the locals-derived GHCR URIs
# win. In ecr mode bootstrap.sh stamps the <account>.dkr.ecr.<region>... URIs
# into tier-3 terraform.tfvars so the effective URI carries the real ECR address.
#-------------------------------------------------------------------------------

variable "uc1_agent_image" {
  type        = string
  description = "ECR image URI override for the UC1 agent container (ecr mode only). In ghcr mode leave empty — the GHCR URI is derived from var.ghcr_registry_base in locals."
  default     = ""
}

variable "banking_app_ui_image" {
  type        = string
  description = "ECR image URI override for the banking app UI container (ecr mode only). In ghcr mode leave empty — the GHCR URI is derived from var.ghcr_registry_base in locals."
  default     = ""
}

variable "banking_app_agent_image" {
  type        = string
  description = "ECR image URI override for the banking app agent container (ecr mode only). In ghcr mode leave empty — the GHCR URI is derived from var.ghcr_registry_base in locals."
  default     = ""
}

variable "banking_app_mcp_image" {
  type        = string
  description = "ECR image URI override for the banking app MCP server container (ecr mode only). In ghcr mode leave empty — the GHCR URI is derived from var.ghcr_registry_base in locals."
  default     = ""
}

variable "uc3_agent_image" {
  type        = string
  description = "ECR image URI override for the UC3 privileged-action agent container (ecr mode only). In ghcr mode leave empty — the GHCR URI is derived from var.ghcr_registry_base in locals."
  default     = ""
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
