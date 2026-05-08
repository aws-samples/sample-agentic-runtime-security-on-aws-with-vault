################################################################################
# bedrock_kb_index Module — Variables
#
# All variables are populated from component.bedrock_kb_aoss outputs in
# infrastructure/components.tfcomponent.hcl.
################################################################################

variable "kb_name" {
  description = "Bedrock Knowledge Base name. Must match the kb_name passed to bedrock_kb_aoss."
  type        = string
  default     = "workshop-kb"
}

variable "aoss_collection_arn" {
  description = "AOSS collection ARN — populated from component.bedrock_kb_aoss.aoss_collection_arn. Used by KB storage_configuration."
  type        = string
}

variable "aoss_collection_endpoint" {
  description = "AOSS collection endpoint URL."
  type        = string
}

variable "kb_role_arn" {
  description = "IAM role ARN for the KB."
  type        = string
}

variable "embedding_model_arn" {
  description = "Nova 2 Multimodal Embeddings model ARN."
  type        = string
}

variable "kb_multimodal_bucket_arn" {
  description = "S3 multimodal storage bucket ARN — required by Nova 2 Embeddings supplementalDataStorageConfiguration."
  type        = string
}

variable "kb_multimodal_bucket_id" {
  description = "S3 multimodal storage bucket name — used to construct the s3:// URI."
  type        = string
}

variable "kb_corpus_bucket_arn" {
  description = "S3 corpus bucket ARN."
  type        = string
}

variable "tags" {
  description = "Tags applied to all taggable resources in this module."
  type        = map(string)
  default     = {}
}
