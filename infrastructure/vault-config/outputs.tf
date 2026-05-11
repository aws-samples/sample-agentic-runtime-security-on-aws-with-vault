################################################################################
# vault_config Local Workspace — Outputs
################################################################################

output "kubernetes_auth_path" {
  value = module.vault_config.kubernetes_auth_path
}

output "jwt_auth_path" {
  value = module.vault_config.jwt_auth_path
}

output "database_mount_path" {
  value = module.vault_config.database_mount_path
}

output "aws_mount_path" {
  value = module.vault_config.aws_mount_path
}

output "uc1_role_name" {
  value = module.vault_config.uc1_role_name
}

output "uc2_role_name" {
  value = module.vault_config.uc2_role_name
}

output "uc3_role_name" {
  value = module.vault_config.uc3_role_name
}
