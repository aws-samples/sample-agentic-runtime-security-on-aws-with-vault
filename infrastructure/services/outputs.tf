################################################################################
# Tier-2 (services) — Outputs
#
# Contract read by:
#   - infrastructure/workloads/   (tier 3: uc1/uc2/uc3)  via remote_state
#   - infrastructure/vault-config/ (JWT auth backend bound_issuer + jwks_ca_pem)
################################################################################

#-------------------------------------------------------------------------------
# IVIA issuer — the single coherence point
# effective_ivia_host prefers the LE-trusted nip.io FQDN, falling back to the
# raw WRP ALB hostname pre-ACME. ivia_issuer = https://<that host>. vault-config
# binds the JWT auth backend's bound_issuer to ivia_issuer; tier 3 consumes
# effective_ivia_host for uc2/uc3 browser-facing wiring + the iviaop patch — so
# iviaop's iss claim and Vault's bound_issuer can never drift.
#-------------------------------------------------------------------------------

output "ivia_issuer" {
  description = "IVIA token issuer (https://<effective-ivia-host>). vault-config wires this into the JWT auth backend's bound_issuer."
  value       = local.ivia_public_issuer
}

output "effective_ivia_host" {
  description = "Resolved browser-facing IVIA host (nip.io FQDN when .acme-state exists, else raw WRP ALB hostname). Consumed by tier-3 uc2/uc3 + iviaop patch so all browser-facing IVIA wiring matches the issuer."
  value       = local.effective_ivia_host
}

output "nip_io_wrp_host" {
  description = "IVIA WRP nip.io FQDN parsed from .acme-state (empty pre-ACME). Surfaced for verify-tls.sh."
  value       = local.nip_io_wrp_host
}

#-------------------------------------------------------------------------------
# IVIA module passthroughs (consumed by tier-3 uc2/uc3)
#-------------------------------------------------------------------------------

output "ivia_namespace" {
  description = "IVIA Kubernetes namespace. Consumed by tier-3 uc3 (ivia_namespace + ivia_runtime_url host)."
  value       = module.ivia.namespace
}

output "ivia_ingress_hostname" {
  description = "Raw IVIA WRP ALB Ingress hostname. Consumed by tier-3 uc2."
  value       = module.ivia.ivia_ingress_hostname
}

output "ivia_service_endpoint" {
  description = "IVIA in-cluster service endpoint. Consumed by tier-3 uc2 (ivia_service_endpoint) + uc3 (ivia_base_url)."
  value       = module.ivia.ivia_service_endpoint
}

output "ivia_client_secret" {
  description = "OAuth client secret for agent-uc2/agent-uc3. Consumed by tier-3 uc2/uc3 + the iviaop clients patch."
  value       = module.ivia.ivia_client_secret
  sensitive   = true
}

output "ivia_oidc_ca_pem" {
  description = "IVIA OIDC Provider self-signed TLS cert. Consumed by tier-3 uc2/uc3 and vault-config (JWT auth backend jwks_ca_pem)."
  value       = module.ivia.ivia_oidc_ca_pem
}

output "ivia_runtime_user" {
  description = "IVIA runtime SCIM user. Consumed by tier-3 uc3."
  value       = module.ivia.ivia_runtime_user
}

output "ivia_runtime_user_password" {
  description = "IVIA runtime SCIM user password. Consumed by tier-3 uc3."
  value       = module.ivia.ivia_runtime_user_password
  sensitive   = true
}

output "ivia_runtime_ca_pem" {
  description = "IVIA runtime self-signed TLS cert. Consumed by tier-3 uc3."
  value       = module.ivia.ivia_runtime_ca_pem
}

#-------------------------------------------------------------------------------
# Vault server passthroughs
#-------------------------------------------------------------------------------

output "vault_namespace" {
  description = "Vault server namespace. Consumed by deploy-workshop.sh (vault-init / vault-configure exec target)."
  value       = module.vault_server.vault_namespace
}

output "vault_endpoint" {
  description = "In-cluster Vault API endpoint. Informational; downstream uses the hardcoded http://vault.vault.svc.cluster.local:8200."
  value       = module.vault_server.vault_endpoint
}

output "vault_service_account" {
  description = "Vault pod ServiceAccount name."
  value       = module.vault_server.vault_service_account
}
