################################################################################
# Vault Module — Outputs (IAM / KMS)
# The KMS key id/arn are consumed by modules/vault_server (tier 2) via the
# tier-1 remote_state read; the IAM role arn/id are consumed by tier-1
# resources (bedrock_kb_aoss trust, uc3-logs-writer trust, the vault assume
# policies).
################################################################################

output "vault_unseal_kms_key_arn" {
  description = "ARN of the dedicated KMS key used for Vault auto-unseal. Separate from the workshop CMK (alias/workshop-data)."
  value       = aws_kms_key.vault_unseal.arn
}

output "vault_unseal_kms_key_id" {
  description = "Key ID of the dedicated KMS unseal key. Passed to the Vault seal stanza in the tier-2 vault_server Helm values."
  value       = aws_kms_key.vault_unseal.key_id
}

output "vault_iam_role_arn" {
  description = "ARN of the Vault Pod Identity IAM role. Used to grant STS assume permissions for the AWS secrets engine and to trust Vault in the KB-role / uc3-logs-writer trust policies."
  value       = aws_iam_role.vault_kms.arn
}

output "vault_iam_role_id" {
  description = "ID of the Vault Pod Identity IAM role. Used for attaching additional IAM policies."
  value       = aws_iam_role.vault_kms.id
}
