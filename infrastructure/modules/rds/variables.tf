################################################################################
# RDS Module — Inputs
# PostgreSQL 17 with pgaudit + connection logging.
################################################################################

variable "identifier" {
  type        = string
  description = "RDS instance identifier. Becomes the prefix for the subnet group, security group, parameter group, and CloudWatch log group names."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the RDS security group is created (output by component.vpc)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the RDS subnet group. RDS deploys in private subnets only (publicly_accessible=false)."
}

variable "cluster_security_group_id" {
  type        = string
  description = "EKS cluster security group ID. The RDS security group's :5432 ingress rule uses this as source_security_group_id (NOT cidr_blocks 0.0.0.0/0). Output by component.eks."
}

variable "node_security_group_id" {
  type        = string
  description = "EKS node security group ID. Pod traffic originates from node ENIs, not the cluster SG. Required for RDS ingress."
}

variable "workshop_cmk_arn" {
  type        = string
  description = "Workshop CMK ARN from the audit module. Used for storage encryption, the master_user_secret KMS key, and the pre-created CloudWatch log group — encryption-context consistency across Phase 2 (Pattern 6)."
}

variable "instance_class" {
  type        = string
  description = "RDS instance class. Default db.t3.medium for <=15 attendees per CONTEXT.md; bump to db.t3.large for >15 (configurable, not pinned)."
  default     = "db.t3.medium"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log group retention in days for the pre-created /aws/rds/instance/<id>/postgresql group. 7 days for workshop ephemeral usage."
  default     = 7
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources in this module."
  default     = {}
}
