################################################################################
# uc2_agent Module — Outputs
################################################################################

output "namespace" {
  description = "Kubernetes namespace where the UC2 banking app runs."
  value       = kubernetes_namespace.banking_app.metadata[0].name
}

output "banking_ui_alb_hostname" {
  description = "ALB hostname assigned to the banking UI Ingress (internet-facing, HTTP-only)."
  value       = kubernetes_ingress_v1.banking_ui.status[0].load_balancer[0].ingress[0].hostname
}

output "banking_ui_service_name" {
  description = "Name of the Kubernetes Service exposing the banking UI (ClusterIP, 80→5173)."
  value       = kubernetes_service.banking_ui_svc.metadata[0].name
}

output "mcp_server_service_name" {
  description = "Name of the Kubernetes Service exposing the MCP server (ClusterIP, 3001→3001)."
  value       = kubernetes_service.banking_mcp_svc.metadata[0].name
}

output "banking_agent_service_name" {
  description = "Name of the Kubernetes Service exposing the Strands agent (ClusterIP, 3002→3002)."
  value       = kubernetes_service.banking_agent_svc.metadata[0].name
}

output "mcp_server_service_account_name" {
  description = "Name of the ServiceAccount bound to the Vault uc2 Kubernetes auth role (uc2-mcp-server-sa)."
  value       = kubernetes_service_account.uc2_mcp_server_sa.metadata[0].name
}
