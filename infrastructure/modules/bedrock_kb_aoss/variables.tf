################################################################################
# bedrock_kb_aoss Module — Variables
################################################################################

variable "region" {
  description = "AWS region. Threads through AOSS encryption policies and any region-flowed resources. Region flows in from the canonical deployments.tfdeploy.hcl variable; no region string literals appear anywhere in this module."
  type        = string
}

variable "kb_name" {
  description = "Bedrock Knowledge Base name. Drives the AOSS policy/collection naming prefix and the IAM role name."
  type        = string
  default     = "workshop-kb"
}

variable "kb_collection_name" {
  description = "OpenSearch Serverless collection name. Used as the resource segment in AOSS policies (collection/<name>)."
  type        = string
  default     = "workshop-kb"
}


variable "workshop_cmk_arn" {
  description = "Unused — retained with default for Stacks removed-block compatibility during region migration. Will be deleted after migration completes."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all taggable resources in this module."
  type        = map(string)
  default     = {}
}
