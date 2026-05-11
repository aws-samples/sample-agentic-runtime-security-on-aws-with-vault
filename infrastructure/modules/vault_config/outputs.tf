################################################################################
# vault_config Module — Outputs
# Consumed by component.vault_config and downstream UC components (Phases 4-6).
################################################################################

output "kubernetes_auth_path" {
  description = "Mount path of the Kubernetes auth backend (value: 'kubernetes'). UC agent Helm charts reference this path in their Vault Agent sidecar annotation."
  value       = "kubernetes"
}

output "jwt_auth_path" {
  description = "Mount path of the JWT auth backend (value: 'jwt'). IVIA token exchange flows use this path."
  value       = "jwt"
}

output "database_mount_path" {
  description = "Mount path of the database secrets engine (value: 'database'). Agents request short-lived PostgreSQL credentials at <database_mount_path>/creds/<role>."
  value       = "database"
}

output "aws_mount_path" {
  description = "Mount path of the AWS secrets engine (value: 'aws'). Agents request STS credentials at <aws_mount_path>/sts/bedrock-reader."
  value       = "aws"
}

output "uc1_role_name" {
  description = "Kubernetes auth role name for Use Case 1 (value: 'uc1'). Vault Agent init container annotation: vault.hashicorp.com/role=uc1."
  value       = "uc1"
}

output "uc2_role_name" {
  description = "Kubernetes auth role name for Use Case 2 (value: 'uc2'). Vault Agent init container annotation: vault.hashicorp.com/role=uc2."
  value       = "uc2"
}

output "uc3_role_name" {
  description = "Kubernetes auth role name for Use Case 3 (value: 'uc3'). Vault Agent init container annotation: vault.hashicorp.com/role=uc3."
  value       = "uc3"
}

output "uc2_jwt_role_name" {
  description = "JWT auth role name for Use Case 2 IVIA token exchange (value: 'uc2-jwt')."
  value       = "uc2-jwt"
}

output "uc3_jwt_role_name" {
  description = "JWT auth role name for Use Case 3 IVIA delegation token exchange (value: 'uc3-jwt')."
  value       = "uc3-jwt"
}
