################################################################################
# Root Module — tier 2 (shared services)
# Agentic Runtime Security Workshop
#
# Deploys the shared-service runtimes that sit BETWEEN core infrastructure and
# the end-user workloads:
#   - Vault server (namespace + SA + Helm release) — modules/vault_server
#   - IBM Verify Identity Access (IVIA) OIDC provider — modules/verify_access
#
# Vault + IVIA are deployable workloads, but NOT end-user apps — they are the
# identity/secrets fabric uc1/uc2/uc3 (tier 3) depend on. This tier reads tier-1
# state via remote_state (local.infra.*) and is applied by deploy-workshop.sh
# AFTER tier 1 + build-images.sh and BEFORE vault-config + tier 3.
#
# The LBC admission webhook readiness gate that used to be a time_sleep in the
# monolithic root is now a kubectl-wait health-check the script runs before this
# apply — the provisioning ORDER (addons before IVIA Ingress) is already
# structural (tier 1 fully applied first); the health-check just confirms the
# already-ordered dependency is Ready.
################################################################################

locals {
  # nip.io FQDN propagation for IVIA WRP MMFA endpoints. The .acme-state file is
  # written by deploy-workshop.sh's ACME step (NIP_FQDN_WRP=
  # wrp.<deploy_id>.<alb_ip_dashed>.nip.io). hashicorp/local's data.local_file
  # fails hard on a missing file, so we use the pure built-ins fileexists() +
  # file() instead — no provider, no failure on absent file.
  #
  # Bootstrap order (NO operator-manual second apply — deploy-workshop.sh
  # drives both applies):
  #   1. First tier-2 apply: .acme-state ABSENT → nip_io_wrp_host="" →
  #      module.ivia falls back to its Ingress-status hostname (degraded but
  #      working); the ALB Ingress + LBC stand up so an ALB IP exists.
  #   2. The ACME step writes .acme-state (NIP_FQDN_WRP=...), then re-applies
  #      tier 2: nip_io_wrp_host populated → module.ivia re-wires to the nip.io
  #      FQDN → base_layer_hash recomputes → autoconf re-runs → AAC DB MMFA
  #      endpoint URLs flip to the LE-trusted nip.io FQDN.
  _acme_state_exists  = fileexists(var.deploy_id_state_path)
  _acme_state_content = local._acme_state_exists ? file(var.deploy_id_state_path) : ""
  nip_io_wrp_host     = try(regex("NIP_FQDN_WRP=([^\n]+)", local._acme_state_content)[0], "")

  # Browser-facing IVIA issuer. Prefer the LE-trusted nip.io FQDN once
  # .acme-state exists; raw ALB only as pre-ACME bootstrap fallback. coalesce()
  # skips the empty-string nip slot. This value is exported (output.ivia_issuer)
  # so vault-config wires it into the JWT auth backend's bound_issuer — the
  # iss claim iviaop stamps and Vault's bound_issuer flip together.
  effective_ivia_host = coalesce(local.nip_io_wrp_host, module.ivia.ivia_ingress_hostname)
  ivia_public_issuer  = "https://${local.effective_ivia_host}"
}

#-------------------------------------------------------------------------------
# Vault server (Helm) — tier 2
# IAM role + KMS unseal key + Pod Identity association are tier 1 (modules/vault_iam).
# This module receives the KMS key id from tier-1 state and stands up the
# namespace + SA + 3-node Raft Helm release.
#-------------------------------------------------------------------------------

module "vault_server" {
  source = "../modules/vault_server"

  region     = local.infra.region
  kms_key_id = local.infra.vault_unseal_kms_key_id
  tags       = local.infra.tags
}

#-------------------------------------------------------------------------------
# IBM Verify Identity Access (IVIA)
# OIDC provider deployed via raw kubernetes_* manifests. tls_certificate_arn is
# the stable tier-1 ACM ARN both browser-facing ALB Ingresses bind. nip_io_wrp_host
# drives the LE-trusted MMFA endpoint rewire after the ACME step.
#-------------------------------------------------------------------------------

module "ivia" {
  source = "../modules/verify_access"

  region                       = local.infra.region
  cluster_name                 = local.infra.cluster_name
  icr_entitlement_key          = var.icr_entitlement_key
  ivia_mmfa_push_client_secret = var.ivia_mmfa_push_client_secret
  node_security_group_id       = local.infra.node_security_group_id
  tls_certificate_arn          = local.infra.tls_certificate_arn
  nip_io_wrp_host              = local.nip_io_wrp_host
  tags                         = local.infra.tags
}
