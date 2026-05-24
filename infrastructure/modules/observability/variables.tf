################################################################################
# Observability Module — Inputs
# fluent-bit DaemonSet + Kinesis Firehose + Glue tables + Athena VIEW
################################################################################

variable "region" {
  type        = string
  description = "AWS region — used for Firehose ARN construction and provider-scoped resources. NEVER hardcode region literals in this module (Pitfall T1)."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used to look up the cluster for Pod Identity association."
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace where fluent-bit DaemonSet runs."
  default     = "logging"
}

variable "log_bucket_name" {
  type        = string
  description = "S3 bucket name for exported logs (Firehose destination). Must be globally unique."
}

variable "glue_database_name" {
  type        = string
  description = "Existing Glue catalog database from the audit module (workshop_logs)."
  default     = "workshop_logs"
}

variable "athena_workgroup" {
  type        = string
  description = "Existing Athena workgroup from the audit module (workshop)."
  default     = "workshop"
}

variable "kms_key_arn" {
  type        = string
  description = "Workshop CMK ARN (alias/workshop-data) — used for S3 SSE on the log export bucket."
}

variable "rds_identifier" {
  type        = string
  description = "RDS instance identifier whose PostgreSQL/pgaudit log group (/aws/rds/instance/<id>/postgresql) is subscribed to Firehose for the UC3 three-plane audit (PLANE-A). Sourced from module.rds.identifier — never a literal region/name."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources in this module."
  default     = {}
}
