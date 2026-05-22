variable "domain_name" {
  description = "Subdomain to create a Route53 public hosted zone for and to issue a wildcard ACM cert under (e.g. demos.devopsoscar.dev). The parent zone owner must delegate NS to this zone's name_servers."
  type        = string
}

variable "tags" {
  description = "Tags applied to the hosted zone and certificate."
  type        = map(string)
  default     = {}
}
