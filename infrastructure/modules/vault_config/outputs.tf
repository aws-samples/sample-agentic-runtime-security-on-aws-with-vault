################################################################################
# vault_config Module — Outputs
# Consumed by component.vault_config and downstream UC components (Phases 4-6).
################################################################################

output "kubernetes_auth_path" {
  description = "Mount path of the Kubernetes auth backend (value: 'kubernetes'). UC agent Helm charts reference this path in their Vault Agent sidecar annotation."
  value       = vault_auth_backend.kubernetes.path
}

output "jwt_auth_path" {
  description = "Mount path of the JWT auth backend (value: 'jwt'). IVIA token exchange flows use this path."
  value       = vault_jwt_auth_backend.ivia.path
}

output "database_mount_path" {
  description = "Mount path of the database secrets engine (value: 'database'). Agents request short-lived PostgreSQL credentials at <database_mount_path>/creds/<role>."
  value       = vault_mount.database.path
}

output "aws_mount_path" {
  description = "Mount path of the AWS secrets engine (value: 'aws'). Agents request STS credentials at <aws_mount_path>/sts/bedrock-reader."
  value       = vault_aws_secret_backend.this.path
}

output "uc1_role_name" {
  description = "Kubernetes auth role name for Use Case 1 (value: 'uc1'). Vault Agent init container annotation: vault.hashicorp.com/role=uc1."
  value       = vault_kubernetes_auth_backend_role.uc1.role_name
}

output "uc2_role_name" {
  description = "Kubernetes auth role name for Use Case 2 (value: 'uc2'). Bound to banking-app namespace / uc2-mcp-server-sa service account."
  value       = vault_kubernetes_auth_backend_role.uc2.role_name
}

output "uc2_db_role_name" {
  description = "Vault database secrets engine role name for Use Case 2 (value: 'uc2-personal-readonly'). SELECT-only on banking schema — ENFC-02 Layer 2 enforcement."
  value       = vault_database_secret_backend_role.uc2_personal_readonly.name
}

output "uc3_role_name" {
  description = "Kubernetes auth role name for Use Case 3 (value: 'uc3'). Vault Agent init container annotation: vault.hashicorp.com/role=uc3."
  value       = vault_kubernetes_auth_backend_role.uc3.role_name
}

output "uc2_jwt_role_name" {
  description = "JWT auth role name for Use Case 2 IVIA token exchange (value: 'uc2-jwt')."
  value       = vault_jwt_auth_backend_role.uc2_jwt.role_name
}

output "uc3_jwt_role_name" {
  description = "JWT auth role name for Use Case 3 IVIA delegation token exchange (value: 'uc3-jwt')."
  value       = vault_jwt_auth_backend_role.uc3_jwt.role_name
}
