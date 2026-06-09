################################################################################
# Vault Server Module — Outputs (tier 2)
################################################################################

output "vault_namespace" {
  description = "Namespace the Vault server runs in. Consumed by deploy-workshop.sh (vault-init / vault-configure exec target)."
  value       = kubernetes_namespace.vault.metadata[0].name
}

output "vault_service_account" {
  description = "ServiceAccount bound to the tier-1 Pod Identity unseal role."
  value       = kubernetes_service_account.vault.metadata[0].name
}

output "vault_endpoint" {
  description = "In-cluster Vault API endpoint (ClusterIP service). Used by the vault-config root and downstream workloads."
  value       = "http://vault.${kubernetes_namespace.vault.metadata[0].name}.svc.cluster.local:8200"
}
