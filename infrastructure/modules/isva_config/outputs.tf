################################################################################
# isva_config Module — Outputs
# Consumed by UC agent components (Phases 4-6) for IVIA OAuth client identity.
#
# Static string defaults: downstream components reference these even when the
# module is disabled (var.enabled = false).  The client IDs and policy name
# are deterministic constants so static values are safe.
################################################################################

output "uc1_client_id" {
  description = "OAuth client ID for Use Case 1 agent (value: 'agent-uc1')."
  value       = "agent-uc1"
}

output "uc2_client_id" {
  description = "OAuth client ID for Use Case 2 agent (value: 'agent-uc2')."
  value       = "agent-uc2"
}

output "uc3_client_id" {
  description = "OAuth client ID for Use Case 3 agent (value: 'agent-uc3')."
  value       = "agent-uc3"
}

output "ciba_policy_name" {
  description = "CIBA policy name registered in IVIA (value: 'workshop-ciba-policy')."
  value       = "workshop-ciba-policy"
}
