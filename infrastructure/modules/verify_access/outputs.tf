################################################################################
# verify_access module outputs.
################################################################################

output "namespace" {
  description = "Kubernetes namespace where all IVIA resources live."
  value       = kubernetes_namespace.verify_access.metadata[0].name
}

output "ivia_wrp_alb_hostname" {
  description = "External ALB hostname for the WRP (HTTP:80 -> HTTPS:9443 backend). Used as the attendee browser entry point and for workshop-e2e.sh OIDC discovery checks."
  value       = try(kubernetes_ingress_v1.ivia_wrp.status[0].load_balancer[0].ingress[0].hostname, "")
}

output "ivia_admin_password" {
  description = "Generated admin password for the IVIA LMI. Consumed by isva_config.ivia_admin_password."
  value       = random_password.ivia_admin_pwd.result
  sensitive   = true
}

