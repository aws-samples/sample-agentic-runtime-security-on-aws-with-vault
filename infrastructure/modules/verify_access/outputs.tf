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

output "ivia_service_endpoint" {
  description = "Cluster-internal Service DNS for the IVIA OIDC Provider runtime (kubernetes_service.iviaop, port 8436). Consumers prepend https:// and :8436."
  value       = "${kubernetes_service.iviaop.metadata[0].name}.${kubernetes_namespace.verify_access.metadata[0].name}.svc.cluster.local"
}

output "ivia_client_secret" {
  description = "IVIA OAuth client secret used by uc2_app and uc3_agent (and uc3-actor) to authenticate to IVIA token + ciba endpoints."
  value       = random_password.ivia_oauth_client_secret.result
  sensitive   = true
}

output "ivia_ingress_hostname" {
  description = "ALB hostname for the IVIA browser entry. Aliased to ivia_wrp_alb_hostname — only one Ingress exists in this module."
  value       = try(kubernetes_ingress_v1.ivia_wrp.status[0].load_balancer[0].ingress[0].hostname, "")
}

output "ivia_oidc_ca_pem" {
  description = "IVIA OIDC Provider self-signed TLS cert (iviaop-config/iviaop.pem) that iviaop serves on :8436. Vault consumes it as jwks_ca_pem to trust the JWKS endpoint. Static repo file — never drifts on a rebuild (unlike the ELB-derived issuer)."
  value       = file("${path.module}/iviaop-config/iviaop.pem")
}

