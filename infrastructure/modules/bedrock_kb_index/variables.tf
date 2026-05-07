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
  description = "AOSS collection endpoint URL — populated from component.bedrock_kb_aoss.aoss_collection_endpoint. Consumed by aws_cloudformation_stack.kb_index template (CollectionEndpoint property of AWS::OpenSearchServerless::Index)."
  type        = string
}

variable "kb_role_arn" {
  description = "IAM role ARN for the KB — populated from component.bedrock_kb_aoss.kb_role_arn. Bedrock service principal assumes this role at runtime."
  type        = string
}

variable "embedding_model_arn" {
  description = "Titan v2 embedding model ARN — populated from component.bedrock_kb_aoss.embedding_model_arn."
  type        = string
}

variable "kb_corpus_bucket_arn" {
  description = "S3 corpus bucket ARN — populated from component.bedrock_kb_aoss.kb_corpus_bucket_arn. Used by all 3 data sources."
  type        = string
}

variable "tags" {
  description = "Tags applied to all taggable resources in this module."
  type        = map(string)
  default     = {}
}
