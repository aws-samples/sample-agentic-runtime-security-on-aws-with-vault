################################################################################
# bedrock_kb Module — Variables
# INFR-04: Bedrock Knowledge Base on OpenSearch Serverless with seeded corpus.
#
# This module rolls the KB by hand from primitives (NOT aws-ia/terraform-aws-bedrock)
# to keep the configuration visible — workshop pedagogy mandate.
################################################################################

variable "region" {
  description = "AWS region. Threads through AOSS encryption policies, opensearch provider, and any data sources. NO us-west-2 string literals anywhere in this module — region flows in from the canonical deployments.tfdeploy.hcl variable."
  type        = string
}

variable "kb_name" {
  description = "Bedrock Knowledge Base name. Drives the AOSS policy/collection naming prefix."
  type        = string
  default     = "workshop-kb"
}

variable "kb_collection_name" {
  description = "OpenSearch Serverless collection name. Used as the resource segment in AOSS policies (collection/<name>)."
  type        = string
  default     = "workshop-kb"
}

variable "workshop_cmk_arn" {
  description = "Workshop CMK ARN from the audit module. Used for AOSS encryption policy KmsARN and S3 corpus bucket SSE-KMS — matches RDS + log group encryption context."
  type        = string
}

variable "tags" {
  description = "Tags applied to all taggable resources in this module."
  type        = map(string)
  default     = {}
}
