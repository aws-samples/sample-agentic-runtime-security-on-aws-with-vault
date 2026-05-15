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
  description = "IBM Container Registry entitlement key for pulling IVIA images (icr.io/ivia/ivia-oidc-provider:25.10). Attendees obtain this from the IBM Cloud console under 'Container Registry' entitlement keys."
}

variable "addons_ready" {
  description = "Consumed but unused — creates implicit ordering so IVIA deploys after the AWS LB Controller webhook is serving."
  type        = any
  default     = null
}

# --- Simple AD (LDAP identity source for user authentication) ---

variable "simple_ad_dns_ips" {
  type        = list(string)
  description = "DNS IP addresses of the Simple AD directory controllers. Used as LDAP hosts in isvaop config.yaml."
}

variable "simple_ad_bind_dn" {
  type        = string
  description = "Administrator bind DN for Simple AD LDAP operations (e.g. CN=Administrator,CN=Users,DC=workshop,DC=internal)."
}

variable "simple_ad_admin_password" {
  type        = string
  sensitive   = true
  description = "Simple AD Administrator password — used as LDAP bind password in isvaop config."
}

variable "simple_ad_base_dn" {
  type        = string
  description = "LDAP base DN for user search (e.g. DC=workshop,DC=internal)."
}

variable "uc2_redirect_uri" {
  type        = string
  default     = "http://localhost:3000/callback"
  description = "OAuth redirect URI for the UC2 banking app. Set to ALB hostname at deploy time."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all AWS resources created by this module."
  default     = {}
}

variable "ivia_trial_cert" {
  type        = string
  description = "Filename of the IVIA trial certificate (.cer) in the infrastructure/ directory. Uploaded to Config container via POST /trial to activate wga, mga, and federation modules. Obtain from https://isva-trial.verify.ibm.com/ if expired."
  default     = "ISAM-Trial-HashiCorp.cer"
}
