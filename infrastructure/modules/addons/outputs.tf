################################################################################
# EKS Blueprints Addons — Outputs
#
# Surface the underlying eks-blueprints-addons module's release attributes so
# Phase 3+ components (Vault, IVIA, agents) can `depends_on` them when they
# need the addon present before their own resources apply.
################################################################################

output "cert_manager_release" {
  description = "cert-manager helm_release attributes (name, namespace, version, status). Phase 3+ components depending on cert-manager-issued certificates can `depends_on` this."
  value       = try(module.eks_blueprints_addons.cert_manager, null)
}

output "external_dns_release" {
  description = "external-dns helm_release attributes. Phase 3+ Ingress/Service resources depending on automatic DNS can `depends_on` this."
  value       = try(module.eks_blueprints_addons.external_dns, null)
}

output "aws_load_balancer_controller_release" {
  description = "AWS Load Balancer Controller helm_release attributes. Phase 3+ Ingress resources depending on ALB provisioning can `depends_on` this."
  value       = try(module.eks_blueprints_addons.aws_load_balancer_controller, null)
}

output "letsencrypt_issuer_name" {
  description = "ClusterIssuer metadata.name for the Let's Encrypt PRODUCTION issuer created by Plan 03. Consumed by Plan 04's Certificate CR (issuerRef.name) which binds the resolved nip.io SANs against this issuer. Value is static — the name is fixed in the ClusterIssuer manifest body and does not depend on a resolved-at-apply attribute."
  value       = "letsencrypt-prod"
}
