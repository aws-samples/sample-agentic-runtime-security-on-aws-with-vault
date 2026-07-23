################################################################################
# vault_config Module — Outputs
# Consumed by component.vault_config and downstream UC components (Phases 4-6).
################################################################################

output "kubernetes_auth_path" {
  description = "Mount path of the Kubernetes auth backend (value: 'kubernetes'). UC agent Helm charts reference this path in their Vault Agent sidecar annotation."
  value       = vault_auth_backend.kubernetes.path
}

output "oauth_resource_server_config_id" {
  description = "Server-assigned config identifier of the IVIA OAuth resource server profile (provider 5.10.1 exposes it as the resource `id`; there is no separate `config_id` attribute). Plan 05 derives the alias mount accessor as oauth-resource-server_root_<this value>."
  value       = vault_oauth_resource_server_config_profile.ivia.id
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

################################################################################
# Native Agent-Identity model (Phase 9, Plan 05) — entity + registration ids
# Consumed by verify scripts (Plan 08) to assert the registry/OBO wiring.
################################################################################

output "uc1_agent_entity_id" {
  description = "Vault identity entity id for the UC1 agent (uc1-agent) — the k8s registry identity."
  value       = vault_identity_entity.uc1_agent.id
}

output "uc1_agent_registration_id" {
  description = "Agent Registry registration id for uc1-agent (registry identity only; ceiling inert)."
  value       = vault_agent_registration.uc1_agent.id
}

output "human_entity_ids" {
  description = "Map of human OAuth sub -> Vault identity entity id for the closed OBO human set {oscar, jaime} (jaime shared once across UC2+UC3)."
  value       = { for k, e in vault_identity_entity.human : k => e.id }
}

output "agent_uc2_entity_id" {
  description = "Vault identity entity id for the UC2 agent (agent-uc2) — the act.sub actor identity."
  value       = vault_identity_entity.agent_uc2.id
}

output "agent_uc2_registration_id" {
  description = "Agent Registry registration id for agent-uc2 (UC2 ceiling; optional_authorization_details=true)."
  value       = vault_agent_registration.agent_uc2.id
}

output "uc3_actor_entity_id" {
  description = "Vault identity entity id for the UC3 agent (uc3-actor) — the act.sub actor identity (NOT the human sub)."
  value       = vault_identity_entity.uc3_actor.id
}

output "uc3_actor_registration_id" {
  description = "Agent Registry registration id for uc3-actor (UC3 ceiling; optional_authorization_details=false, RAR mandatory)."
  value       = vault_agent_registration.uc3_actor.id
}
