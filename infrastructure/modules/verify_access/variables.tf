################################################################################
# Verify Access Module — Variables
# IBM Verify Identity Access 11.0.2 OIDC Provider
################################################################################

variable "region" {
  type        = string
  description = "AWS region for deployment. All resource references interpolate this — no literal region strings."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used for tagging and labeling."
}

variable "rds_endpoint" {
  type        = string
  description = "RDS full endpoint in <address>:<port> form from component.rds.endpoint. Used as informational output only; host/port split vars are used for K8s secret construction."
}

variable "rds_address" {
  type        = string
  description = "RDS hostname (without port) from component.rds.address. Injected into isvaop-server K8s secret as PostgreSQL host."
}

variable "rds_port" {
  type        = number
  description = "RDS listening port from component.rds.port (5432). Injected into isvaop-server K8s secret."
}

variable "rds_master_username" {
  type        = string
  description = "RDS master username from component.rds.master_username. Bootstrap-only — Vault vends short-lived creds post-deploy."
}

variable "rds_master_user_secret_arn" {
  type        = string
  sensitive   = true
  description = "ARN of the RDS-managed Secrets Manager secret for the master user password (component.rds.master_user_secret_arn). Secret value is JSON with keys 'username' and 'password'."
}

variable "rds_db_name" {
  type        = string
  description = "Initial database name from component.rds.db_name (workshop)."
}

variable "vault_endpoint" {
  type        = string
  description = "Vault ClusterIP service URL from component.vault.vault_endpoint (e.g., http://vault.vault.svc.cluster.local:8200). Used as OIDC seam reference in IVIA config."
}

variable "audit_log_group_names" {
  type        = map(string)
  description = "Map of audit CloudWatch log group names from component.audit.audit_log_group_names. Used to configure IVIA decision-log syslog output target."
}

variable "icr_entitlement_key" {
  type        = string
  sensitive   = true
  description = "IBM Container Registry entitlement key for pulling IVIA images (icr.io/ivia/ivia-oidc-provider:26.03). Attendees obtain this from the IBM Cloud console under 'Container Registry' entitlement keys."
}

variable "addons_ready" {
  description = "Consumed but unused — creates implicit Stacks ordering so IVIA deploys after the AWS LB Controller webhook is serving."
  type        = any
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all AWS resources created by this module."
  default     = {}
}
