################################################################################
# EKS Module Variables
################################################################################

variable "region" {
  description = "AWS region (canonical region from deployments.tfdeploy.hcl; used to format the kubectl one-liner output)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the cluster will be deployed (passed from component.vpc.vpc_id)"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the EKS cluster and managed node group (passed from component.vpc.private_subnet_ids)"
  type        = list(string)
}

variable "admin_principal_arn" {
  description = "ARN of the workshop admin IAM principal granted cluster-admin via EKS Access Entries (replaces aws-auth ConfigMap)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all EKS resources"
  type        = map(string)
  default     = {}
}
