################################################################################
# uc1_agent Module — Outputs
################################################################################

output "agent_namespace" {
  description = "Kubernetes namespace where the UC1 agent runs."
  value       = "uc1"
}

output "agent_service_name" {
  description = "Name of the Kubernetes Service exposing the UC1 agent (ClusterIP)."
  value       = "uc1-agent-svc"
}

output "agent_deployment_name" {
  description = "Name of the Kubernetes Deployment for the UC1 agent."
  value       = "uc1-agent"
}

output "agent_service_account_name" {
  description = "Name of the ServiceAccount bound to the Vault uc1 Kubernetes auth role."
  value       = "uc1-retriever-sa"
}
