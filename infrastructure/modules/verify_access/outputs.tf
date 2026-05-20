################################################################################
# verify_access module outputs.
################################################################################

output "namespace" {
  description = "Kubernetes namespace where all IVIA resources live."
  value       = kubernetes_namespace.verify_access.metadata[0].name
}

output "ivia_lmi_nlb_hostname" {
  description = "External NLB hostname for the LMI (TCP:9443). Used by isva_config Mastercard/restapi provider (var.ivia_service_endpoint)."
  value       = try(kubernetes_service.iviaconfig_nlb.status[0].load_balancer[0].ingress[0].hostname, "")
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

output "ivia_nlb_ready" {
  description = "Gate resource consumers can depend_on to ensure the NLB has had ~90s to provision before they construct URIs against ivia_lmi_nlb_hostname."
  value       = time_sleep.ivia_nlb_ready.id
}
