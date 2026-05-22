variable "region" {
  type        = string
  description = "AWS region."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Used for tagging only — provider config comes from root."
}

variable "icr_entitlement_key" {
  type        = string
  sensitive   = true
  description = "IBM Container Registry entitlement key. Used to build the 'dockerlogin' kubernetes.io/dockerconfigjson Secret in the 'verify-access' namespace."
}

variable "node_security_group_id" {
  type        = string
  description = "EKS worker node shared security group ID. Used to add a cross-node TCP/636 (LDAPS) self-source ingress rule so pdconfig on iviaruntime can reach openldap pod across nodes."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to AWS resources created by this module (the SG rule)."
}

variable "tls_certificate_arn" {
  type        = string
  description = "Validated ACM cert ARN attached to the WRP ALB HTTPS:443 listener (wildcard *.<workshop_domain>)."
}

variable "public_hostname" {
  type        = string
  description = "Public HTTPS hostname for the WRP/IVIAOP browser entry point (e.g. login.demos.devopsoscar.dev). Drives provider.yml base_url + issuer and the ALB cert binding."
}
