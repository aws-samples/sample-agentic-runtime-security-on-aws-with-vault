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
  description = "Generated admin password for the IVIA LMI. Consumed by the workshop_layer autoconf Job (kubernetes_job_v1.ivia_workshop_autoconf)."
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

################################################################################
# Workshop-layer autoconf re-use outputs
# Consumed by the root-level kubernetes_job_v1.ivia_workshop_autoconf so it can
# reuse the ServiceAccount, RBAC, and image-pull secret already provisioned by
# this module. The Job lives in root main.tf (not here) because it must depend
# on module.uc2_app.banking_ui_alb_hostname — an out-of-module reference.
################################################################################

output "ivia_autoconf_sa_name" {
  description = "ServiceAccount used by the base_layer autoconf Job; reused for the workshop_layer Job."
  value       = kubernetes_service_account.ivia_autoconf.metadata[0].name
}

output "dockerlogin_secret_name" {
  description = "Image-pull Secret for the IBM Container Registry (icr.io) login; reused by the workshop_layer autoconf Job."
  value       = kubernetes_secret.dockerlogin.metadata[0].name
}

output "ivia_admin_secret_name" {
  description = "Secret holding the LMI admin password (key: adminpw); reused by the workshop_layer autoconf Job."
  value       = kubernetes_secret.ivia_admin.metadata[0].name
}

