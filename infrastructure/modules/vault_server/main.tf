################################################################################
# Vault Server Module — tier 2 (shared services)
#
# Owns the Vault *server* runtime only:
#   - vault namespace
#   - vault ServiceAccount (Pitfall V1: chart serviceAccount.create=false)
#   - Helm release (hashicorp/vault 0.32.0, 3-node Raft HA, KMS auto-unseal)
#
# The KMS unseal key + the Pod Identity IAM role + the Pod Identity association
# all live in tier 1 (modules/vault), because module.bedrock_kb_aoss names the
# Vault IAM role as a trusted principal and AWS rejects a trust policy that names
# a non-existent principal. This module receives the KMS key id via the tier-1
# remote_state read and binds the seal stanza to it.
#
# The Pod Identity association (tier 1) is name-based — it maps namespace=vault /
# service_account=vault to the IAM role and resolves lazily when a vault pod asks
# for credentials. So the association exists before this SA is created; no
# cross-tier resource dependency is needed beyond the structural tier-1→tier-2
# ordering enforced by deploy-workshop.sh.
#
# Pitfall H1: helm provider MUST be ~> 2.17 (NOT 3.x — set{} syntax break).
################################################################################

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17" # Pitfall H1 — DO NOT bump to 3.x
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

################################################################################
# Vault Namespace
################################################################################

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

################################################################################
# Vault Service Account
# Created explicitly because the Helm chart's serviceAccount.create is false
# (Pitfall V1). The tier-1 Pod Identity association maps THIS SA to the unseal
# IAM role. Without this resource, the StatefulSet fails:
#   "pods vault-0 is forbidden: serviceaccount vault not found"
################################################################################

resource "kubernetes_service_account" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "vault"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

################################################################################
# Vault Enterprise License Secret
# Enterprise binary hard-fails init without an autoloaded license (Phase 9).
# License content is a per-attendee deploy input (var.vault_enterprise_license,
# sensitive, no default) sourced from a file by deploy-workshop.sh — NEVER a
# committed literal. Mirrors the kubernetes_secret shape in
# verify_access/main.tf:516-526. Referenced by Helm server.enterpriseLicense
# below (secretName/secretKey) and listed in the helm_release depends_on so
# the secret exists before the chart installs.
################################################################################

resource "kubernetes_secret" "vault_ent_license" {
  metadata {
    name      = "vault-ent-license"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  type = "Opaque"
  data = {
    license = var.vault_enterprise_license
  }
}

################################################################################
# Vault Helm Release
# Chart: hashicorp/vault 0.32.0 (Vault server image hashicorp/vault-enterprise:2.0.3-ent)
# HA values rendered from vault-ha.yaml.tpl. KMS key id is supplied by tier 1.
#
# POST-DEPLOY — Two-phase bootstrap (handled by deploy-workshop.sh):
#   Vault starts sealed + uninitialized. KMS auto-unseal handles unsealing;
#   initialization is a one-time operation performed by vault-init.sh:
#     kubectl exec -n vault vault-0 -- vault operator init -format=json
#   The root token is captured into the runtime environment and consumed by the
#   vault-config root — it is NEVER written to Terraform state.
################################################################################

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.32.0"
  namespace  = kubernetes_namespace.vault.metadata[0].name

  values = [
    templatefile("${path.module}/values/vault-ha.yaml.tpl", {
      kms_key_id = var.kms_key_id
      region     = var.region
    })
  ]

  wait    = true
  timeout = 600

  depends_on = [
    kubernetes_service_account.vault,
    kubernetes_secret.vault_ent_license,
  ]
}
