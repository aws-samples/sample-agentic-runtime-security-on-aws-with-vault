################################################################################
# uc1_agent Module — Variables
#
# Inputs for the UC1 non-personalized read-only Strands agent Kubernetes
# resources (namespace, ServiceAccount, ConfigMap, Deployment, Service,
# NetworkPolicy).
################################################################################

variable "vault_addr" {
  description = "Vault cluster-internal address reachable from the uc1 namespace."
  type        = string
  default     = "http://vault.vault.svc.cluster.local:8200"
}

variable "vault_role" {
  description = "Vault Kubernetes auth role name bound to uc1-retriever-sa."
  type        = string
  default     = "uc1"
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

variable "knowledge_base_id" {
  description = "Amazon Bedrock Knowledge Base ID used by the UC1 agent for retrieval."
  type        = string
}

variable "region" {
  description = "Primary AWS region where the EKS cluster and Vault run."
  type        = string
}

variable "kb_region" {
  description = "AWS region where the Bedrock Knowledge Base is deployed (must match the KB embedding model region)."
  type        = string
}

variable "agent_image" {
  description = "Container image URI for the UC1 agent. In ghcr mode this is the GHCR :v1 URI derived from locals in the workloads root; in ecr mode it is the ECR URI stamped by bootstrap."
  type        = string
}

variable "image_pull_policy" {
  description = "Kubernetes imagePullPolicy for the UC1 agent container. IfNotPresent for ghcr mode (pinned :v1 tag); Always for ecr mode (mutable :latest). Set by the workloads root; default keeps a standalone module plan valid."
  type        = string
  default     = "IfNotPresent"
}

variable "bedrock_model_id" {
  description = "Bedrock inference profile ID for the LLM used by the UC1 agent."
  type        = string
  default     = "us.amazon.nova-pro-v1:0"
}

variable "tags" {
  description = "AWS resource tags propagated to taggable resources (informational — Kubernetes resources do not support AWS tags)."
  type        = map(string)
  default     = {}
}
