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

variable "lmi_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR allowlist for inbound NLB on TCP/9443 (LMI). Default open for workshop; attendees may lock to their public IP via tfvars override (e.g. [\"203.0.113.42/32\"])."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to AWS resources created by this module (the SG rule)."
}
