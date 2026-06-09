################################################################################
# Tier-3 (workloads) — Outputs
#
# Browser-facing banking-ui hostnames. Not script-load-bearing (the ACME step
# discovers ALB hostnames via `kubectl get ingress`, and Vault/IVIA issuer
# coherence is anchored in tier 2), but surfaced for verification + parity with
# the contract tier 1 exposed before the workloads moved to this root.
################################################################################

output "banking_ui_alb_hostname" {
  description = "Raw banking-ui ALB Ingress hostname (k8s-...elb.amazonaws.com). Pre-ACME bootstrap host; superseded by the nip.io FQDN once .acme-state is written."
  value       = module.uc2_app.banking_ui_alb_hostname
}

output "effective_banking_host" {
  description = "Resolved browser-facing banking-ui host: the LE-trusted nip.io FQDN (NIP_FQDN_BANKING) when .acme-state exists, else the raw ALB hostname. This is the host the agent-uc2 OAuth redirect_uri (https://<host>/callback) is built from."
  value       = local.effective_banking_host
}
