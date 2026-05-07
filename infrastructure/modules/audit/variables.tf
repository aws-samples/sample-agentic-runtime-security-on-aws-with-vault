################################################################################
# Audit Module — Inputs
# Workshop CMK + 3 audit log groups + Glue catalog + Athena workgroup.
################################################################################

variable "region" {
  type        = string
  description = "AWS region — used to interpolate the CloudWatch Logs service principal in the workshop CMK key policy (logs.<region>.amazonaws.com). NEVER hardcode region literals in this module (Pitfall T1)."
}

variable "audit_retention_days" {
  type        = number
  description = "CloudWatch log group retention in days for /workshop/* audit log groups. Default 7 days for workshop ephemeral usage (Pitfall R2 mitigation: short retention controls ingestion costs at pgaudit log='ddl,write,role')."
  default     = 7
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources in this module."
  default     = {}
}
