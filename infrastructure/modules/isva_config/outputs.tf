################################################################################
# isva_config Module — Outputs
# Consumed by UC agent components (Phases 4-6) for IVIA OAuth client identity.
################################################################################

output "uc1_client_id" {
  description = "OAuth client ID for Use Case 1 agent (value: 'agent-uc1'). UC1 agent Helm chart references this for client_credentials token request."
  value       = jsondecode(restapi_object.uc1_client.api_response).client_id
}

output "uc2_client_id" {
  description = "OAuth client ID for Use Case 2 agent (value: 'agent-uc2'). UC2 agent uses this for authorization_code + PKCE flow."
  value       = jsondecode(restapi_object.uc2_client.api_response).client_id
}

output "uc3_client_id" {
  description = "OAuth client ID for Use Case 3 agent (value: 'agent-uc3'). UC3 agent uses this for CIBA grant initiation."
  value       = jsondecode(restapi_object.uc3_client.api_response).client_id
}

output "ciba_policy_name" {
  description = "CIBA policy name registered in IVIA (value: 'workshop-ciba-policy'). UC3 agent references this policy in the backchannel authentication request."
  value       = jsondecode(restapi_object.ciba_policy.api_response).name
}
