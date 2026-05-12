################################################################################
# Simple AD Module — Variables
# AWS Simple AD for workshop user authentication (Oscar, Adriana)
################################################################################

variable "region" {
  type        = string
  description = "AWS region for deployment."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID — Simple AD deploys ENIs into this VPC."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Two private subnet IDs in different AZs for Simple AD."
}

variable "eks_node_security_group_id" {
  type        = string
  description = "EKS node security group ID — allowed LDAP ingress to Simple AD."
}

variable "admin_password" {
  type        = string
  sensitive   = true
  description = "Administrator password for Simple AD. Used for LDAP bind and user provisioning."
}

variable "domain_name" {
  type        = string
  default     = "workshop.internal"
  description = "FQDN for the Simple AD directory."
}

variable "short_name" {
  type        = string
  default     = "WORKSHOP"
  description = "NetBIOS short name for the directory."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
