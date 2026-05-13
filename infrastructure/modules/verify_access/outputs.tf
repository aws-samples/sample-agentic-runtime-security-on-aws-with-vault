################################################################################
# Verify Access Module — Outputs
# Consumed by Plan 03-03 vault_config (jwt auth method OIDC discovery URL)
# and UC2/UC3 agents for user-context delegation via CIBA/RAR.
################################################################################

output "ivia_oidc_discovery_url" {
  description = "Internal OIDC discovery URL for IVIA (ClusterIP path)."
  value       = "https://${kubernetes_service.isvaop.metadata[0].name}.${kubernetes_namespace.verify_access.metadata[0].name}.svc.cluster.local:8436/oauth2/.well-known/openid-configuration"
}

output "ivia_jwks_url" {
  description = "IVIA JWKS URL (cluster-internal). Used by Vault jwt auth backend to fetch signing keys. Preferred over oidc_discovery_url because Vault's discovery validation fails with self-signed certs."
  value       = "https://${kubernetes_service.isvaop.metadata[0].name}.${kubernetes_namespace.verify_access.metadata[0].name}.svc.cluster.local:8436/oauth2/jwks"
}

output "ivia_issuer" {
  description = "IVIA token issuer URL. Matches the iss claim in IVIA-issued JWTs (external ALB, HTTP)."
  value       = "http://${try(kubernetes_ingress_v1.isvaop.status[0].load_balancer[0].ingress[0].hostname, "")}"
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
  value       = "http://${try(kubernetes_ingress_v1.isvaop.status[0].load_balancer[0].ingress[0].hostname, "")}"
}

output "ivia_tls_cert_pem" {
  description = "IVIA self-signed TLS certificate PEM. Passed to Vault jwt auth backend as oidc_discovery_ca_pem so Vault trusts the IVIA OIDC discovery endpoint."
  value       = tls_self_signed_cert.isvaop.cert_pem
  sensitive   = true
}

output "ivia_client_secret" {
  description = "IVIA OAuth client secret for the agent-uc2 client. Wired to uc2_agent ConfigMap so the banking-ui ROPC login can authenticate with IVIA."
  value       = random_password.client_secret.result
  sensitive   = true
}
