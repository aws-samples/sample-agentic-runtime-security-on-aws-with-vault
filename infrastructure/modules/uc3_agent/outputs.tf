################################################################################
# uc3_agent Module — Outputs
################################################################################

output "service_name" {
  description = "Kubernetes Service name for the UC3 agent (uc3-agent-svc). Use this for in-cluster DNS: uc3-agent-svc.<namespace>.svc.cluster.local:8080."
  value       = kubernetes_service.uc3_agent.metadata[0].name
}

output "service_account_name" {
  description = "Name of the ServiceAccount bound to the Vault uc3 Kubernetes auth role (uc3-privileged-actor-sa)."
  value       = kubernetes_service_account.uc3_agent.metadata[0].name
}
