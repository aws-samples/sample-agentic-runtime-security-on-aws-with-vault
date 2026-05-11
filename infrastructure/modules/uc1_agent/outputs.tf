################################################################################
# uc1_agent Module — Outputs
################################################################################

output "agent_namespace" {
  description = "Kubernetes namespace where the UC1 agent runs."
  value       = kubernetes_namespace.uc1.metadata[0].name
}

output "agent_service_name" {
  description = "Name of the Kubernetes Service exposing the UC1 agent (ClusterIP)."
  value       = kubernetes_service.uc1.metadata[0].name
}

output "agent_deployment_name" {
  description = "Name of the Kubernetes Deployment for the UC1 agent."
  value       = kubernetes_deployment.uc1.metadata[0].name
}

output "agent_service_account_name" {
  description = "Name of the ServiceAccount bound to the Vault uc1 Kubernetes auth role."
  value       = kubernetes_service_account.uc1.metadata[0].name
}
