################################################################################
# VPC Module Variables
################################################################################

variable "region" {
  description = "AWS region; canonical value comes from infrastructure/deployments.tfdeploy.hcl. Used to construct interface endpoint service names. The region MUST NOT be hard-coded as a string literal anywhere in this module."
  type        = string
}

variable "cluster_name" {
  description = "Workshop cluster name. Used as VPC name prefix and for SG/endpoint Name tagging."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Defaults to 10.1.0.0/16 (workshop default; reference repo uses 10.0.0.0/16, this workshop intentionally diverges to 10.1 to keep parallel deployments distinct on attendee laptops)."
  type        = string
  default     = "10.1.0.0/16"
}

variable "azs" {
  description = "List of 3 availability zones (sourced from deployments.tfdeploy.hcl). Subnet count is derived from this list — supply exactly 3 entries."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 3
    error_message = "var.azs must contain exactly 3 availability zones (workshop topology assumes 3-AZ spread)."
  }
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}
