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
  description = "IVIA OIDC Provider self-signed TLS cert (tls_self_signed_cert.iviaop) that iviaop serves on :8436. Vault consumes it as jwks_ca_pem to trust the JWKS endpoint; uc2/uc3 agents trust it as their CA bundle. Terraform-owned (was committed iviaop-config/iviaop.pem) — no private key at rest in git; the public cert is stable across pod restarts because the keypair lives in state."
  value       = tls_self_signed_cert.iviaop.cert_pem
}

output "ivia_runtime_user" {
  description = "AAC runtime service user (easuser) for HTTP Basic on the admin SCIM read. Consumed by uc3_agent IVIA_SCIM_USER."
  value       = local.ivia_runtime_user
}

output "ivia_runtime_user_password" {
  description = "Generated password for the AAC runtime service user (easuser). uc3_agent uses it for HTTP Basic on the admin SCIM read that resolves MMFA transaction status (the CIBA mobile-push approval gate)."
  value       = random_password.ivia_runtime_user_pwd.result
  sensitive   = true
}

output "ivia_runtime_ca_pem" {
  description = "AAC runtime (iviaruntime) Terraform-owned serving cert (CN=isam). uc3_agent PINS this as the CA (check_hostname=False) for the SCIM read + MMFA push-fire. State-derived from tls_self_signed_cert.iviaruntime, installed into IVIA's rt_profile_keys keystore (label \"server\") by the autoconf job — stable across iviaruntime pod restarts AND module.ivia rebuilds. See README § \"TLS serving cert ownership\"."
  value       = tls_self_signed_cert.iviaruntime.cert_pem
}

#-------------------------------------------------------------------------------
# OBO identity constants (Plan 05, BLOCKER 1) — the act.sub actor + human sub
# values IVIA emits. Single source of truth (local.obo_*, cited against
# clients.yml.tftpl + base_layer.yaml.tftpl). Re-exported by tier-2 services and
# consumed by vault-config so the Vault entity aliases bind to the exact values.
#-------------------------------------------------------------------------------

output "uc2_agent_identity" {
  description = "UC2 agent OAuth act.sub ACTOR value (agent-uc2). Consumed by vault-config for the UC2 actor alias."
  value       = local.obo_uc2_agent_identity
}

output "uc3_agent_identity" {
  description = "UC3 agent OAuth act.sub ACTOR value (uc3-actor) — the token-exchange performer, NOT the human sub. Consumed by vault-config for the UC3 actor alias."
  value       = local.obo_uc3_agent_identity
}

output "uc3_human_sub" {
  description = "UC3 human OAuth sub SUBJECT value (jaime), the sole CIBA refund approver. Consumed by vault-config for the shared jaime subject alias."
  value       = local.obo_uc3_human_sub
}

output "uc2_human_subs" {
  description = "UC2 closed human OAuth sub set ([oscar, jaime]). Consumed by vault-config for the UC2 subject aliases (jaime deduped across UC2+UC3)."
  value       = local.obo_uc2_human_subs
}

