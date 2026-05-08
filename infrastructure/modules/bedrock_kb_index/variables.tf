################################################################################
# bedrock_kb_index Module — Variables
#
# All variables are populated from component.bedrock_kb_aoss outputs in
# infrastructure/components.tfcomponent.hcl.
# Defaults provided for Stacks removed-block destroy compatibility.
################################################################################

variable "kb_name" {
  description = "Bedrock Knowledge Base name. Must match the kb_name passed to bedrock_kb_aoss."
  type        = string
  default     = "workshop-kb"
}

variable "aoss_collection_arn" {
  description = "AOSS collection ARN — populated from component.bedrock_kb_aoss.aoss_collection_arn. Used by KB storage_configuration."
  type        = string
  default     = ""
}

variable "aoss_collection_endpoint" {
  description = "AOSS collection endpoint URL."
  type        = string
  default     = ""
}

variable "kb_role_arn" {
  description = "IAM role ARN for the KB."
  type        = string
  default     = ""
}

variable "embedding_model_arn" {
  description = "Embedding model ARN."
  type        = string
  default     = ""
}

variable "kb_corpus_bucket_arn" {
  description = "S3 corpus bucket ARN."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all taggable resources in this module."
  type        = map(string)
  default     = {}
}
