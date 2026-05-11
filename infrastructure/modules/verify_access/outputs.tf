################################################################################
# Verify Access Module — Outputs
# Consumed by Plan 03-03 vault_config (jwt auth method OIDC discovery URL)
# and UC2/UC3 agents for user-context delegation via CIBA/RAR.
################################################################################

output "ivia_oidc_discovery_url" {
  description = "Internal OIDC discovery URL for IVIA (ClusterIP path). Vault jwt auth method consumes this to fetch JWKS and validate tokens."
  value       = "https://${kubernetes_service.isvaop.metadata[0].name}.${kubernetes_namespace.verify_access.metadata[0].name}.svc.cluster.local:8436/.well-known/openid-configuration"
}

output "ivia_namespace" {
  description = "Kubernetes namespace where IVIA is deployed (verify-access)."
  value       = kubernetes_namespace.verify_access.metadata[0].name
}

output "ivia_service_endpoint" {
  description = "IVIA ClusterIP service DNS endpoint (without scheme or path). Format: isvaop.verify-access.svc.cluster.local"
  value       = "${kubernetes_service.isvaop.metadata[0].name}.${kubernetes_namespace.verify_access.metadata[0].name}.svc.cluster.local"
}

output "ivia_ingress_hostname" {
  description = "ALB hostname provisioned by AWS Load Balancer Controller for external OIDC discovery. May be empty until the LBC reconciles the Ingress resource."
  value       = try(kubernetes_ingress_v1.isvaop.status[0].load_balancer[0].ingress[0].hostname, "")
}

output "ivia_external_endpoint" {
  description = "IVIA external endpoint via ALB (scheme + host). Used by the restapi provider in isva_config since HCP Terraform cannot reach cluster-internal DNS."
  value       = "https://${try(kubernetes_ingress_v1.isvaop.status[0].load_balancer[0].ingress[0].hostname, "")}"
}
