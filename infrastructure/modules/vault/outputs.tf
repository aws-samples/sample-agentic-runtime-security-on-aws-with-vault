################################################################################
# Vault Module — Outputs
# Consumed by downstream Phase 3+ components (IVIA, agents).
################################################################################

output "vault_endpoint" {
  description = "Vault API endpoint — ClusterIP service DNS (in-cluster access only)."
  value       = "http://vault.vault.svc.cluster.local:8200"
}

output "vault_namespace" {
  description = "Kubernetes namespace where Vault is deployed."
  value       = kubernetes_namespace.vault.metadata[0].name
}

output "vault_service_account" {
  description = "Kubernetes service account name used by Vault pods (bound to KMS unseal Pod Identity role)."
  value       = "vault"
}

output "vault_unseal_kms_key_arn" {
  description = "ARN of the dedicated KMS key used for Vault auto-unseal. Separate from the workshop CMK (alias/workshop-data)."
  value       = aws_kms_key.vault_unseal.arn
}

output "vault_unseal_kms_key_id" {
  description = "Key ID of the dedicated KMS unseal key. Passed to the Vault seal stanza in Helm values."
  value       = aws_kms_key.vault_unseal.key_id
}
