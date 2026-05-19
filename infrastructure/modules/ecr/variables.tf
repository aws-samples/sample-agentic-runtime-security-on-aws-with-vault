variable "repository_names" {
  type        = list(string)
  description = "ECR repository names to create. Build scripts push images to these."
  default     = ["workshop/uc1-agent", "workshop/uc3-agent", "workshop-banking-app"]
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Resource tags propagated from root module."
}
