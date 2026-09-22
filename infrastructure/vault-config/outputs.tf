################################################################################
# vault_config Local Workspace — Outputs
################################################################################

output "kubernetes_auth_path" {
  value = module.vault_config.kubernetes_auth_path
}

output "oauth_resource_server_config_id" {
  value = module.vault_config.oauth_resource_server_config_id
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

# The OAuth identity set, forwarded so vault-configure.sh can assert that every
# identity actually has an entity alias at the LIVE oauth-resource-server profile
# (issue #5). Deriving the expected set from terraform rather than a hardcoded
# list means adding a human to the workshop widens the gate automatically.
output "human_entity_ids" {
  value = module.vault_config.human_entity_ids
}

output "agent_uc2_entity_id" {
  value = module.vault_config.agent_uc2_entity_id
}

output "uc3_actor_entity_id" {
  value = module.vault_config.uc3_actor_entity_id
}
