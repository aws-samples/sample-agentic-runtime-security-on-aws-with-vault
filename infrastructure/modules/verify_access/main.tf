################################################################################
# IBM Verify Identity Access (IVIA) — 7-deployment Kubernetes module.
#
# Replaces the legacy single-pod-sidecar + RDS-HVDB + shell-curl autoconfig
# module with the sibling-repo verify-access-container-deployment proven happy
# path:
#   - 7 deployments (openldap, postgresql, iviaconfig, iviadsc, iviaop,
#     iviaruntime, iviawrprp1) in single 'verify-access' namespace.
#   - Pinned image tags (LMI/DSC/Runtime/WRP/Postgres 11.0.2.0,
#     OIDC Provider 25.10, OpenLDAP 10.0.6.0).
#   - In-cluster kubernetes_job_v1 running python -m ibmvia_autoconf 0.3.21
#     against a MINIMAL webseal.runtime base_layer.yaml.
#   - LMI is NOT exposed externally — admin-only, one-time bring-up via
#     `kubectl port-forward svc/iviaconfig 9443:9443` (4 manual browser steps).
#   - WRP browser exposure via ALB Ingress (the OIDC/UC entry point).
#
# Phase 7 plan: .planning/phases/07-ivia-deployment-refactor/
# Sibling reference: ~/git-repos/verify-access-container-deployment/phase-a/
################################################################################

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.25" }
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    time       = { source = "hashicorp/time", version = "~> 0.9" }
    archive    = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

locals {
  namespace = "verify-access"
  common_labels = {
    "app.kubernetes.io/part-of"    = "ivia"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

#-------------------------------------------------------------------------------
# Namespace
#-------------------------------------------------------------------------------

resource "kubernetes_namespace" "verify_access" {
  metadata {
    name   = local.namespace
    labels = local.common_labels
  }
}

#-------------------------------------------------------------------------------
# ICR image pull secret. Sibling pod manifests reference 'dockerlogin' verbatim
# (phase-a/ivia-eks.yaml imagePullSecrets blocks). Username 'iamapikey' is the
# target-verified form (RESEARCH §2.5, §7.2). Sibling uses 'cp'; both work for
# IBM entitlement keys.
#-------------------------------------------------------------------------------

resource "kubernetes_secret" "dockerlogin" {
  metadata {
    name      = "dockerlogin"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "icr.io" = {
          username = "iamapikey"
          password = var.icr_entitlement_key
          auth     = base64encode("iamapikey:${var.icr_entitlement_key}")
        }
      }
    })
  }
}

#-------------------------------------------------------------------------------
# IBM Verify mobile-push (MMFA) provider credential. The VerifyPushCreds API Key
# (= Client Secret for ISVA 10.0.3+) authenticates the AAC runtime to the IBM
# Verify push relay (verifypushcreds.verify.ibm.com). Held as the named Secret
# 'ivia-mmfa-push'; the AAC push_notification_providers config resolves it via
# the autoconf `!secret verify-access/ivia-mmfa-push:imc_client_secret` syntax
# (wired in a later increment). count gates creation on a supplied value so this
# is a no-op until MMFA is configured.
#-------------------------------------------------------------------------------

resource "kubernetes_secret" "ivia_mmfa_push" {
  count = var.ivia_mmfa_push_client_secret != "" ? 1 : 0
  metadata {
    name      = "ivia-mmfa-push"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    imc_client_secret = var.ivia_mmfa_push_client_secret
  }
}

#-------------------------------------------------------------------------------
# RBAC for the autoconf Job. ibmvia_autoconf 0.3.21 requires:
#   - get/list secrets + configmaps   for !secret <ns>/<name>:<key> resolution
#   - get/list/patch deployments.apps for _restart_k8s_deployments
# (RESEARCH §8.3, evidenced by the RuntimeError trace at data_util.py:43 when
#  run outside a pod — see RESEARCH Pitfall 1.)
#-------------------------------------------------------------------------------

resource "kubernetes_service_account" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  image_pull_secret {
    name = kubernetes_secret.dockerlogin.metadata[0].name
  }
}

resource "kubernetes_role" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps"]
    verbs      = ["get", "list"]
  }
  rule {
    # Pods list/get — autoconf's _kube_rollout_restart enumerates pods before
    # patching the deployment template to trigger a rollout.
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch"]
  }
}

resource "kubernetes_role_binding" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ivia_autoconf.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ivia_autoconf.metadata[0].name
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }
}

#-------------------------------------------------------------------------------
# Persistent Volume Claims — 5 PVCs, gp2 RWO 50M each.
# Sibling source: phase-a/ivia-eks.yaml:24-82.
# `wait_until_bound = false` matches target idiom (verify_access legacy
# module used same pattern); EBS gp2 is bound when the consumer pod schedules.
#-------------------------------------------------------------------------------

locals {
  ivia_pvcs = {
    ldaplib          = "/var/lib/ldap"              # consumed by openldap
    ldapslapd        = "/etc/ldap/slapd.d"          # consumed by openldap
    ldapsecauthority = "/var/lib/ldap.secAuthority" # consumed by openldap
    postgresqldata   = "/var/lib/postgresql/data"   # consumed by postgresql
    iviaconfig       = "/var/shared"                # consumed by iviaconfig
  }
}

resource "kubernetes_persistent_volume_claim" "ivia" {
  for_each         = local.ivia_pvcs
  wait_until_bound = false
  metadata {
    name      = each.key
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "gp2"
    resources {
      requests = {
        storage = "50M"
      }
    }
  }
}

#-------------------------------------------------------------------------------
# Application credentials — random_password resources. 24 chars, no special
# chars (matches target's legacy module style; some IVIA fields choke on
# quotes/backslashes; safest to avoid). One resource per credential.
#-------------------------------------------------------------------------------

resource "random_password" "ivia_admin_pwd" {
  length  = 24
  special = false
}

# cfgsvc service account uses the SAME password as admin — matches sibling-repo
# parity ("1 password: Passw0rd"). configreader.cfgsvcpw references this directly.

resource "random_password" "openldap_admin_pwd" {
  length  = 24
  special = false
}

resource "random_password" "openldap_config_pwd" {
  length  = 24
  special = false
}

resource "random_password" "postgresql_pwd" {
  length  = 24
  special = false
}

resource "random_password" "wrp_p12_secret" {
  length  = 24
  special = false
}

# PKCS#12 protection password for the Terraform-owned iviaruntime serving cert.
# Used by the autoconf job to seal the in-cluster-minted .p12 before importing
# into IVIA's rt_profile_keys keystore via LMI. Static across applies — the .p12
# is regenerated only when the cert pem changes; rotating the seal password on
# every apply would force a re-mint without solving anything.
resource "random_password" "ivia_runtime_p12_secret" {
  length  = 24
  special = false
}

resource "random_password" "sec_master_pwd" {
  length  = 24
  special = false
}

# IVIA OAuth client secret. Consumed by uc2_app + uc3_agent via the
# ivia_client_secret module output. Stable across applies (rotation is
# out of scope for Phase 07.1 — no keepers block).
# special=false: 32 chars provide ample entropy and the secret is sent in
# HTTP basic auth + form-urlencoded bodies, where special chars complicate
# consumers without adding meaningful entropy.

resource "random_password" "ivia_oauth_client_secret" {
  length  = 32
  special = false
}

# AAC runtime service user (easuser) password — increment 2. Used for HTTP Basic
# to the localscim server_connection, the /scim junction, and the mmfa/aac
# configuration runtime block. Set on the runtime's Liberty basic registry via
# container.runtime_properties.users in base_layer.yaml.tftpl.
resource "random_password" "ivia_runtime_user_pwd" {
  length  = 24
  special = false
}

# Dedicated SCIM LDAP bind (cn=iviascim) password. The SCIM service binds AS this
# least-privilege account to resolve users (wrp_runtime server_connection), instead
# of the LDAP root bind. Generated here and static for the deployment; Vault-managed
# rotation is the documented future improvement (see README "SCIM bind account").
resource "random_password" "ivia_scim_bind_pwd" {
  length  = 24
  special = false
}

#-------------------------------------------------------------------------------
# postgresql TLS material. Sibling: kubernetes/create-secrets.sh:25-27 creates a
# Secret with a single key 'server.pem'. POSTGRES_SSL_KEYDB env var on the
# postgresql container points to /var/local/server.pem.
#
# The PEM must contain both the private key AND the cert (PostgreSQL's
# combined keydb format). We concatenate cert_pem + private_key_pem.
#-------------------------------------------------------------------------------

resource "tls_private_key" "postgresql" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "postgresql" {
  private_key_pem = tls_private_key.postgresql.private_key_pem

  subject {
    common_name  = "postgresql"
    organization = "ibm"
    country      = "US"
  }

  validity_period_hours = 87600 # 10 years
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = ["postgresql", "postgresql.verify-access.svc.cluster.local"]
}

#-------------------------------------------------------------------------------
# iviaruntime serving cert (Liberty defaultKeyStore — rt_profile_keys, label
# "server"). Replaces the auto-self-signed cert Liberty mints on every cold
# start in the absence of a pre-provisioned personal cert.
#
# Before this resource existed: iviaruntime had no PVC, so on every pod restart
# Liberty regenerated a fresh self-signed cert in
# /var/pdweb/shared/keytab/rt_profile_keys.p12 (verified via server.xml
# defaultKeyStore + LMI GET /isam/ssl_certificates/rt_profile_keys/personal_cert).
# uc3-agent pins this cert (mmfa.py _runtime_ssl_context, check_hostname=False),
# so the pinned static iviaruntime.pem in the iviaop-config/ dir went stale on
# every restart — breaking the MMFA push-fire TLS handshake.
#
# With this resource: Terraform state owns the keypair. The autoconf job imports
# it into rt_profile_keys via LMI (label "server", replacing the auto-gen cert
# of the same label) — see autoconf args block below for the delete-then-import
# monkey-patch. iviaconfig's PVC persists the KDB across rebuilds, so the cert
# survives both iviaruntime pod restarts AND module.ivia destroy+recreate.
#
# CN=isam matches what the existing IVIA internal SCIM/MMFA caller paths
# already expect for the runtime serving cert (the auto-gen one is also CN=isam,
# O=ibm, C=us). uc3-agent disables hostname verification on this pin so the SAN
# list is for cluster-DNS hygiene only.
#-------------------------------------------------------------------------------

resource "tls_private_key" "iviaruntime" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "iviaruntime" {
  private_key_pem = tls_private_key.iviaruntime.private_key_pem

  subject {
    common_name  = "isam"
    organization = "ibm"
    country      = "us"
  }

  validity_period_hours = 87600 # 10 years
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [
    "iviaruntime",
    "iviaruntime.verify-access.svc.cluster.local",
  ]
}

#-------------------------------------------------------------------------------
# iviaop keypair (isvaop_keys/httpserverkey) — DOUBLE DUTY:
#   1. TLS serving cert on :8436 (provider.yml ssl.server key/certificate)
#   2. RS256 JWT signing key (provider.yml signing_keystore=isvaop_keys,
#      signing_keylabel=httpserverkey) — the id_token signing key.
# Terraform state owns the keypair instead of committing iviaop.key/iviaop.pem
# (AWS security review: no private keys at rest in git). Regenerating is SAFE:
# every truster fetches the public half live via JWKS (Vault jwt auth jwks_url)
# or via the ivia_oidc_ca_pem output (uc2 + uc3 agents), so a rotated key flows
# through with no pinning. The public cert (.cert_pem) feeds the iviaop-config
# ConfigMap, the base_layer signer truststore, AND outputs.tf ivia_oidc_ca_pem;
# the private key (.private_key_pem_pkcs8 — PKCS#8, required by the Liberty/Java
# ISVAOP PEM loader) lives ONLY in kubernetes_secret.iviaop_key, never a
# ConfigMap. CN/SAN reproduce the previous committed cert exactly so hostname
# verification by Vault (jwks_ca_pem) and the agents' CA-bundle trust still pass.
#-------------------------------------------------------------------------------

resource "tls_private_key" "iviaop" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "iviaop" {
  private_key_pem = tls_private_key.iviaop.private_key_pem

  subject {
    common_name  = "iviaop.verify-access.svc.cluster.local"
    organization = "ibm"
    country      = "US"
  }

  validity_period_hours = 87600 # 10 years
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [
    "iviaop",
    "iviaop.verify-access",
    "iviaop.verify-access.svc",
    "iviaop.verify-access.svc.cluster.local",
  ]
}

#-------------------------------------------------------------------------------
# openldap serving keypair (LDAPS :636). Terraform state owns it instead of the
# committed base_layer/openldap-keys/ldap.key + ldap.crt + ca.crt (AWS security
# review). The previous committed set was self-signed with ldap.crt == ca.crt
# (byte-identical), so one generated self-signed cert fills BOTH the leaf
# (ldap.crt) and trust-anchor (ca.crt) slots; IVIA imports ldap.crt as an
# lmi_trust_store signer to trust the LDAPS endpoint it binds to. CN=openldap
# reproduces the previous cert; a DNS SAN is added (the committed cert had none)
# so modern SAN-checking TLS clients validate cleanly. dhparam.pem is public
# (DH params, not a key) and stays committed. PKCS#8 private key for loader
# compatibility.
#-------------------------------------------------------------------------------

resource "tls_private_key" "openldap" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "openldap" {
  private_key_pem = tls_private_key.openldap.private_key_pem

  subject {
    common_name  = "openldap"
    organization = "ibm"
    country      = "us"
  }

  validity_period_hours = 87600 # 10 years
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  # IVIA binds LDAPS to the bare host "openldap" (base_layer.yaml.tftpl `host: "openldap"`).
  # The previous committed cert had NO SAN (CN-only); adding a SAN makes CN matching moot
  # per RFC 6125, so the SAN MUST include every form a client could connect with — bare
  # host first, plus the cluster-DNS forms — or a SAN-checking TLS client hard-fails.
  dns_names = [
    "openldap",
    "openldap.verify-access",
    "openldap.verify-access.svc",
    "openldap.verify-access.svc.cluster.local",
  ]
}

#-------------------------------------------------------------------------------
# iviawrprp1 (WebSEAL/WRP) serving keypair — pdsrv keystore personal cert "WRP",
# served on :443/:9443. Terraform state owns it instead of the committed binary
# base_layer/iviawrprp1.p12 (AWS security review — no private key at rest in git,
# incl. binary PKCS#12). Same mint-at-deploy pattern already proven for
# iviaruntime.p12: the public PEM cert + private key flow into the base_layer
# ConfigMap, the autoconf preamble seals them into iviawrprp1.p12 (sealed with
# random_password.wrp_p12_secret — the regeneration the wrp_p12_creds comment
# always anticipated), and LMI imports the p12 into pdsrv. CN/SAN reproduce the
# previous committed cert (CN=isvawrp.ibm.com) plus cluster-DNS forms.
#-------------------------------------------------------------------------------

resource "tls_private_key" "iviawrprp1" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "iviawrprp1" {
  private_key_pem = tls_private_key.iviawrprp1.private_key_pem

  subject {
    common_name  = "isvawrp.ibm.com"
    organization = "ibm"
    country      = "us"
  }

  validity_period_hours = 87600 # 10 years
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [
    "www.iamlab.ibm.com",
    "iviawrprp1",
    "iviawrprp1.verify-access",
    "iviawrprp1.verify-access.svc",
    "iviawrprp1.verify-access.svc.cluster.local",
  ]
}

#-------------------------------------------------------------------------------
# kubernetes_secret bundle. All names match sibling's pod-manifest references
# and base_layer.yaml `!secret verify-access/<name>:<key>` lookups
# (RESEARCH §8.5 + §8.6).
#
# Target idiom: data = { key = plain_string }. The Kubernetes provider
# base64-encodes on submit. DO NOT pre-encode (RESEARCH §2.8).
#-------------------------------------------------------------------------------

resource "kubernetes_secret" "ivia_admin" {
  metadata {
    name      = "iviaadmin"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    adminpw = random_password.ivia_admin_pwd.result
  }
}

resource "kubernetes_secret" "configreader" {
  metadata {
    name      = "configreader"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    cfgsvcpw = random_password.ivia_admin_pwd.result
  }
}

resource "kubernetes_secret" "openldap_creds" {
  metadata {
    name      = "openldap-creds"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    admin_password  = random_password.openldap_admin_pwd.result
    config_password = random_password.openldap_config_pwd.result
  }
}

resource "kubernetes_secret" "openldap_keys" {
  metadata {
    name      = "openldap-keys"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  # ldap.crt / ldap.key / ca.crt are Terraform-generated (tls_self_signed_cert.openldap)
  # so no private key sits in git — the leaf and CA slots share the one self-signed
  # cert (the previous committed set had ldap.crt == ca.crt). dhparam.pem is public
  # DH params (not a key), still sourced from the committed file via binary_data.
  data = {
    "ldap.crt" = tls_self_signed_cert.openldap.cert_pem
    "ldap.key" = tls_private_key.openldap.private_key_pem_pkcs8
    "ca.crt"   = tls_self_signed_cert.openldap.cert_pem
  }
  binary_data = {
    "dhparam.pem" = filebase64("${path.module}/base_layer/openldap-keys/dhparam.pem")
  }
}

resource "kubernetes_secret" "postgresql_keys" {
  metadata {
    name      = "postgresql-keys"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    # Combined cert + key — postgresql expects both in the SSL_KEYDB file.
    "server.pem" = "${tls_self_signed_cert.postgresql.cert_pem}${tls_private_key.postgresql.private_key_pem}"
  }
}

resource "kubernetes_secret" "postgresql_creds" {
  metadata {
    name      = "postgresql-creds"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    password = random_password.postgresql_pwd.result
  }
}

resource "kubernetes_secret" "wrp_p12_creds" {
  metadata {
    name      = "wrp-p12-creds"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    # Sealing password for the in-cluster-minted iviawrprp1.p12. The committed
    # binary .p12 is gone (AWS security review) — the autoconf preamble now mints
    # it from the Terraform-owned iviawrprp1 PEM keypair, sealed with this random
    # password, exactly the regeneration this secret always anticipated. base_layer.yaml
    # unwraps via `!secret verify-access/wrp-p12-creds:secret`, so the seal here and
    # the LMI import password stay in lockstep. No hardcoded seal password.
    secret = random_password.wrp_p12_secret.result
  }
}

resource "kubernetes_secret" "ivia_runtime_p12_creds" {
  metadata {
    name      = "ivia-runtime-p12-creds"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    # Sealing password for the in-cluster-minted iviaruntime.p12. Referenced by
    # base_layer.yaml.tftpl's rt_profile_keys.personal_certificates[0].secret
    # via `!secret verify-access/ivia-runtime-p12-creds:secret`. Autoconf
    # resolves the !secret reference, fetches this value, and passes it to
    # LMI POST /isam/ssl_certificates/{kdb}/personal_cert as the unwrap pw.
    secret = random_password.ivia_runtime_p12_secret.result
  }
}

resource "kubernetes_secret" "ivia_secauthority_creds" {
  metadata {
    name      = "ivia-secauthority-creds"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    sec_master_password = random_password.sec_master_pwd.result
  }
}

# AAC runtime service user (easuser) — increment 2. base_layer.yaml.tftpl
# references this as `!secret verify-access/ivia-runtime-user:password`.
resource "kubernetes_secret" "ivia_runtime_user" {
  metadata {
    name      = "ivia-runtime-user"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    password = random_password.ivia_runtime_user_pwd.result
  }
}

# Dedicated SCIM LDAP bind (cn=iviascim) — generated, least-privilege service
# account. base_layer.yaml.tftpl references this as
# `!secret verify-access/ivia-scim-bind:bind_pwd` (both the pdadmin user create
# and the wrp_runtime server_connection bind_pwd); autoconf resolves it at config
# time. Password is static for the deployment; Vault-managed rotation is the
# documented future improvement (see README "SCIM bind account" section).
resource "kubernetes_secret" "ivia_scim_bind" {
  metadata {
    name      = "ivia-scim-bind"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    bind_pwd = random_password.ivia_scim_bind_pwd.result
  }
}

#-------------------------------------------------------------------------------
# openldap — LDAP backend for secAuthority=Default + dc=ibm,dc=com.
# Sibling source: phase-a/ivia-eks.yaml:84-160.
# Args LOCKED: --loglevel trace --copy-service (CONTEXT, sibling).
#-------------------------------------------------------------------------------

resource "kubernetes_deployment" "openldap" {
  metadata {
    name      = "openldap"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "openldap" })
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "openldap" } }
    template {
      metadata { labels = { app = "openldap" } }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        volume {
          name = "ldaplib"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ivia["ldaplib"].metadata[0].name
          }
        }
        volume {
          name = "ldapslapd"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ivia["ldapslapd"].metadata[0].name
          }
        }
        volume {
          name = "ldapsecauthority"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ivia["ldapsecauthority"].metadata[0].name
          }
        }
        volume {
          name = "openldap-keys"
          secret {
            secret_name = kubernetes_secret.openldap_keys.metadata[0].name
          }
        }

        container {
          name  = "openldap"
          image = "icr.io/isva/verify-access-openldap:10.0.6.0"
          args  = ["--loglevel", "trace", "--copy-service"]

          port { container_port = 636 }

          env {
            name  = "LDAP_DOMAIN"
            value = "ibm.com"
          }
          env {
            name = "LDAP_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.openldap_creds.metadata[0].name
                key  = "admin_password"
              }
            }
          }
          env {
            name = "LDAP_CONFIG_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.openldap_creds.metadata[0].name
                key  = "config_password"
              }
            }
          }

          volume_mount {
            name       = "ldaplib"
            mount_path = "/var/lib/ldap"
          }
          volume_mount {
            name       = "ldapslapd"
            mount_path = "/etc/ldap/slapd.d"
          }
          volume_mount {
            name       = "ldapsecauthority"
            mount_path = "/var/lib/ldap.secAuthority"
          }
          volume_mount {
            name       = "openldap-keys"
            mount_path = "/container/service/slapd/assets/certs"
          }

          readiness_probe {
            tcp_socket { port = 636 }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket { port = 636 }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "openldap" {
  metadata {
    name      = "openldap"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "openldap" })
  }
  spec {
    selector = { app = "openldap" }
    port {
      port     = 636
      name     = "ldaps"
      protocol = "TCP"
    }
  }
}

#-------------------------------------------------------------------------------
# postgresql — HVDB (runtime DB, sessions, cluster DB). Pod-local; NOT shared RDS.
# Sibling source: phase-a/ivia-eks.yaml:162-237.
# securityContext LOCKED runAsUser=26 fsGroup=26 — upstream's 70/85 crashes
# (RESEARCH Pitfall 4).
# NO container args — only openldap carries --loglevel/--copy-service.
#-------------------------------------------------------------------------------

resource "kubernetes_deployment" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "postgresql" })
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "postgresql" } }
    template {
      metadata { labels = { app = "postgresql" } }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        security_context {
          run_as_non_root = true
          run_as_user     = 26
          fs_group        = 26
        }

        volume {
          name = "postgresqldata"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ivia["postgresqldata"].metadata[0].name
          }
        }
        volume {
          name = "postgresql-keys"
          secret {
            secret_name = kubernetes_secret.postgresql_keys.metadata[0].name
          }
        }

        container {
          name  = "postgresql"
          image = "icr.io/ivia/ivia-postgresql:11.0.2.0"

          port { container_port = 5432 }

          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgresql_creds.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name  = "POSTGRES_DB"
            value = "ivia"
          }
          env {
            name  = "POSTGRES_SSL_KEYDB"
            value = "/var/local/server.pem"
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/db-files/"
          }

          volume_mount {
            name       = "postgresqldata"
            mount_path = "/var/lib/postgresql/data"
          }
          volume_mount {
            name       = "postgresql-keys"
            mount_path = "/var/local"
          }

          readiness_probe {
            tcp_socket { port = 5432 }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket { port = 5432 }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "postgresql" })
  }
  spec {
    selector = { app = "postgresql" }
    port {
      port     = 5432
      name     = "postgresql"
      protocol = "TCP"
    }
  }
}

#-------------------------------------------------------------------------------
# iviaconfig — LMI (Local Management Interface) on :9443. Source of truth for
# IVIA configuration snapshots. Consumed by autoconf Job, iviadsc, iviaop,
# iviaruntime, iviawrprp1 (all of them config-pull at startup).
# Sibling source: phase-a/ivia-eks.yaml:239-317.
#-------------------------------------------------------------------------------

resource "kubernetes_deployment" "iviaconfig" {
  metadata {
    name      = "iviaconfig"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviaconfig" })
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "iviaconfig" } }
    template {
      metadata { labels = { app = "iviaconfig" } }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        security_context {
          run_as_non_root = true
          run_as_user     = 6000
          fs_group        = 6000
        }

        volume {
          name = "iviaconfig"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ivia["iviaconfig"].metadata[0].name
          }
        }
        volume {
          name = "iviaconfig-logs"
          empty_dir {}
        }

        container {
          name  = "iviaconfig"
          image = "icr.io/ivia/ivia-config:11.0.2.0"

          port { container_port = 9443 }

          env {
            name  = "CONTAINER_TIMEZONE"
            value = "Europe/London"
          }
          env {
            name = "ADMIN_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_admin.metadata[0].name
                key  = "adminpw"
              }
            }
          }

          volume_mount {
            name       = "iviaconfig"
            mount_path = "/var/shared"
          }
          volume_mount {
            name       = "iviaconfig-logs"
            mount_path = "/var/application.logs"
          }

          readiness_probe {
            http_get {
              path   = "/core/login"
              port   = 9443
              scheme = "HTTPS"
            }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 2
          }
          liveness_probe {
            exec {
              command = ["/sbin/health_check.sh", "livenessProbe"]
            }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 6
          }
          startup_probe {
            exec {
              command = ["/sbin/health_check.sh"]
            }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 30
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "iviaconfig" {
  metadata {
    name      = "iviaconfig"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviaconfig" })
  }
  spec {
    selector = { app = "iviaconfig" }
    port {
      port        = 9443
      target_port = 9443
      name        = "iviaconfig"
      protocol    = "TCP"
    }
  }
}

#-------------------------------------------------------------------------------
# iviaop-config ConfigMap. 9 files mounted at /var/isvaop/config in the iviaop
# pod. storage.yml is templated to substitute the postgresql password (CONTEXT R2
# — sidesteps the chicken-and-egg "iviaop boots before autoconf publishes the
# Liberty config" race). clients.yml registers agent-uc1 + agent-uc3 statically;
# agent-uc2 is registered post-deploy via DCR (kubernetes_job in root main.tf)
# because its redirect_uri depends on the banking-ui ALB hostname.
# Sibling source: common/isvaop-config/ (+ workshop-specific clients.yml).
#-------------------------------------------------------------------------------

resource "kubernetes_config_map" "iviaop_config" {
  metadata {
    name      = "iviaop-config"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  data = {
    # provider.yml ships with a placeholder issuer/base_url. The real values are
    # the ivia-wrp (login) ALB hostname, which only exists after this module's
    # Ingress reconciles — and this ConfigMap is created before that. The root
    # module patches the provider.yml key with the real ALB issuer via
    # kubernetes_config_map_v1_data.iviaop_clients_patch + an iviaop rollout
    # (same indirection as clients.yml). IVIAOP rejects http redirect_uris for
    # non-localhost, so the patched value is always https://<alb-host>.
    "provider.yml" = templatefile("${path.module}/iviaop-config/provider.yml.tftpl", {
      ivia_public_url    = "https://issuer-patched-at-root.invalid/isvaop"
      ivia_public_issuer = "https://issuer-patched-at-root.invalid"
    })
    "rules.yaml"        = file("${path.module}/iviaop-config/rules.yaml")
    "accesspolicy.yaml" = file("${path.module}/iviaop-config/accesspolicy.yaml")
    "storage.yml" = templatefile("${path.module}/iviaop-config/storage.yml", {
      postgres_password = random_password.postgresql_pwd.result
    })
    # clients.yml rendered with a placeholder uc2_redirect_uri. The real ALB
    # hostname (only known after module.uc2_app deploys the banking-ui Ingress)
    # is patched in at root level by `kubernetes_config_map_v1_data.iviaop_clients_patch`
    # followed by `null_resource.iviaop_rollout_restart`. This indirection
    # breaks the otherwise-circular dep: module.uc2_app depends on module.ivia
    # outputs, so module.ivia cannot in turn read from module.uc2_app.
    "clients.yml" = templatefile("${path.module}/iviaop-config/clients.yml.tftpl", {
      ivia_client_secret = random_password.ivia_oauth_client_secret.result
      uc2_redirect_uri   = "http://placeholder.invalid/callback"
    })
    # iviaop.key is NOT here — the RS256 signing/serving PRIVATE key lives in
    # kubernetes_secret.iviaop_key (never a ConfigMap, unencrypted at rest). Only
    # the PUBLIC cert stays in the ConfigMap. Both are merged into /var/isvaop/config
    # via the projected volume on the iviaop Deployment below.
    "iviaop.pem"     = tls_self_signed_cert.iviaop.cert_pem
    "iviawrprp1.pem" = file("${path.module}/iviaop-config/iviawrprp1.pem")
    # Dynamic — must match the cert the postgresql pod serves (postgresql-keys.server.pem)
    "postgres.crt" = tls_self_signed_cert.postgresql.cert_pem
  }
  binary_data = {
    "templates.zip" = filebase64("${path.module}/iviaop-config/templates.zip")
  }

  # provider.yml and clients.yml are created here with PLACEHOLDER ALB hostnames
  # (issuer-patched-at-root.invalid / placeholder.invalid), then overwritten
  # out-of-band by the root-module kubernetes_config_map_v1_data.iviaop_clients_patch
  # with the real ALB issuer + redirect_uri once the ALBs exist. Without this
  # ignore_changes the base resource would revert the patched real values back to
  # the placeholders on every apply — perpetual drift, and a stray apply would
  # break the live OIDC issuer (iviaop would advertise *.invalid and the banking
  # login redirect would dead-end). The patch owns these two keys after creation.
  lifecycle {
    ignore_changes = [
      data["provider.yml"],
      data["clients.yml"],
    ]
  }
}

#-------------------------------------------------------------------------------
# iviaop signing/serving PRIVATE key — held in a Secret (encryptable at rest),
# NOT the iviaop-config ConfigMap (AWS security review: no private keys in a
# ConfigMap). The iviaop Deployment merges this Secret alongside the ConfigMap
# into /var/isvaop/config via a projected volume, so ISVAOP loads iviaop.key
# exactly as before. PKCS#8 PEM — the Liberty/Java ISVAOP loader requires the
# unencrypted PKCS#8 header form (BEGIN PRIVATE KEY), not PKCS#1's RSA variant.
#-------------------------------------------------------------------------------
resource "kubernetes_secret" "iviaop_key" {
  metadata {
    name      = "iviaop-key"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  data = {
    "iviaop.key" = tls_private_key.iviaop.private_key_pem_pkcs8
  }
}

#-------------------------------------------------------------------------------
# iviadsc — Distributed Session Cache.
# Sibling source: phase-a/ivia-eks.yaml:482-561.
# LOCKED bug fix: Service selector is `app: iviadsc` (NOT upstream's `app: isvadsc`).
#-------------------------------------------------------------------------------

resource "kubernetes_deployment" "iviadsc" {
  # Cannot reach Ready until autoconf creates the DSC instance (post-LMI bring-up).
  # Sibling phase-a/03-ivia-deploy.sh uses `kubectl apply` (no wait) for this reason.
  wait_for_rollout = false

  metadata {
    name      = "iviadsc"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviadsc" })
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "iviadsc" } }
    template {
      metadata { labels = { app = "iviadsc" } }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        volume {
          name = "iviaconfig"
          empty_dir {}
        }
        volume {
          name = "iviadsc-logs"
          empty_dir {}
        }

        container {
          name  = "iviadsc"
          image = "icr.io/ivia/ivia-dsc:11.0.2.0"

          port { container_port = 9443 }
          port { container_port = 9444 }

          env {
            name  = "INSTANCE"
            value = "1"
          }
          env {
            name  = "CONTAINER_TIMEZONE"
            value = "Europe/London"
          }
          env {
            name  = "CONFIG_SERVICE_URL"
            value = "https://iviaconfig:9443/shared_volume"
          }
          env {
            name  = "CONFIG_SERVICE_USER_NAME"
            value = "cfgsvc"
          }
          env {
            name = "CONFIG_SERVICE_USER_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.configreader.metadata[0].name
                key  = "cfgsvcpw"
              }
            }
          }
          env {
            name  = "CONFIG_SERVICE_TLS_CACERT"
            value = "disabled"
          }

          volume_mount {
            name       = "iviaconfig"
            mount_path = "/var/shared"
          }
          volume_mount {
            name       = "iviadsc-logs"
            mount_path = "/var/application.logs"
          }

          readiness_probe {
            exec { command = ["/sbin/health_check.sh"] }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 2
          }
          liveness_probe {
            exec { command = ["/sbin/health_check.sh", "livenessProbe"] }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 6
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "iviadsc" {
  metadata {
    name      = "iviadsc"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviadsc" })
  }
  spec {
    selector = { app = "iviadsc" } # LOCKED: NOT 'isvadsc' (upstream bug)
    port {
      port        = 9443
      target_port = 9443
      name        = "iviadsc-svc"
      protocol    = "TCP"
    }
    port {
      port        = 9444
      target_port = 9444
      name        = "iviadsc-rep"
      protocol    = "TCP"
    }
  }
}

#-------------------------------------------------------------------------------
# iviaop — OAuth/OIDC token endpoint on :8436. Behind WRP junction /isvaop.
# Sibling source: phase-a/ivia-eks.yaml:563-628.
# Image tag 25.10 is DISTINCT from the 11.0.2.0 family — do NOT substitute.
#-------------------------------------------------------------------------------

resource "kubernetes_deployment" "iviaop" {
  # Cannot reach Ready until autoconf wires DB config + LDAP (post-LMI bring-up).
  wait_for_rollout = false

  metadata {
    name      = "iviaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviaop" })
    annotations = {
      version = "2.0"
    }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "iviaop" } }
    template {
      metadata {
        labels = { app = "iviaop" }
        # Forces a rolling restart whenever any file in iviaop-config changes
        # (provider.yml, clients.yml, certs, etc.). The iviaop container only
        # reads /var/isvaop/config on startup — without this, ConfigMap edits
        # would be invisible until the next pod recreation.
        annotations = {
          # Hash BOTH the ConfigMap data and the private-key Secret so a rotation
          # of either (incl. the state-derived iviaop.key/iviaop.pem) rolls the pod.
          "checksum/iviaop-config" = sha256(jsonencode(merge(
            kubernetes_config_map.iviaop_config.data,
            kubernetes_secret.iviaop_key.data,
          )))
        }
      }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        # Projected volume merges the iviaop-config ConfigMap (provider.yml,
        # clients.yml, iviaop.pem, …) with the iviaop-key Secret (iviaop.key) into
        # one directory at /var/isvaop/config, so ISVAOP sees the same file layout
        # while the private key comes from a Secret, not a ConfigMap.
        volume {
          name = "iviaop-config"
          projected {
            sources {
              config_map {
                name = kubernetes_config_map.iviaop_config.metadata[0].name
              }
            }
            sources {
              secret {
                name = kubernetes_secret.iviaop_key.metadata[0].name
              }
            }
          }
        }

        container {
          name              = "iviaop"
          image             = "icr.io/ivia/ivia-oidc-provider:25.10"
          image_pull_policy = "Always"

          volume_mount {
            name       = "iviaop-config"
            mount_path = "/var/isvaop/config"
          }

          readiness_probe {
            http_get {
              path   = "/healthcheck/ready"
              port   = 8436
              scheme = "HTTPS"
            }
            initial_delay_seconds = 30
            timeout_seconds       = 30
            period_seconds        = 30
            success_threshold     = 1
            failure_threshold     = 2
          }
          liveness_probe {
            http_get {
              path   = "/healthcheck/alive"
              port   = 8436
              scheme = "HTTPS"
            }
            initial_delay_seconds = 30
            timeout_seconds       = 30
            period_seconds        = 30
            success_threshold     = 1
            failure_threshold     = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "iviaop" {
  metadata {
    name      = "iviaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviaop" })
  }
  spec {
    selector = { app = "iviaop" }
    port {
      port        = 8436
      target_port = 8436
      name        = "iviaop"
      protocol    = "TCP"
    }
  }
}

#-------------------------------------------------------------------------------
# iviaruntime — AAC runtime. Sibling source: phase-a/ivia-eks.yaml:399-480.
#-------------------------------------------------------------------------------

resource "kubernetes_deployment" "iviaruntime" {
  # Cannot reach Ready until cfgsvc password sync + LMI snapshot publish.
  wait_for_rollout = false

  metadata {
    name      = "iviaruntime"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviaruntime" })
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "iviaruntime" } }
    template {
      metadata { labels = { app = "iviaruntime" } }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        volume {
          name = "iviaconfig"
          empty_dir {}
        }
        volume {
          name = "iviaruntime-logs"
          empty_dir {}
        }

        container {
          name  = "iviaruntime"
          image = "icr.io/ivia/ivia-runtime:11.0.2.0"

          port { container_port = 9443 }

          env {
            name  = "CONTAINER_TIMEZONE"
            value = "Europe/London"
          }
          env {
            name  = "CONFIG_SERVICE_URL"
            value = "https://iviaconfig:9443/shared_volume"
          }
          env {
            name  = "CONFIG_SERVICE_USER_NAME"
            value = "cfgsvc"
          }
          env {
            name = "CONFIG_SERVICE_USER_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.configreader.metadata[0].name
                key  = "cfgsvcpw"
              }
            }
          }
          env {
            name  = "CONFIG_SERVICE_TLS_CACERT"
            value = "disabled"
          }

          volume_mount {
            name       = "iviaconfig"
            mount_path = "/var/shared"
          }
          volume_mount {
            name       = "iviaruntime-logs"
            mount_path = "/var/application.logs"
          }

          readiness_probe {
            http_get {
              path   = "/sps/static/ibm-logo.png"
              port   = 9443
              scheme = "HTTPS"
            }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 2
          }
          liveness_probe {
            exec { command = ["/sbin/health_check.sh", "livenessProbe"] }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 6
          }
          startup_probe {
            exec { command = ["/sbin/health_check.sh"] }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 30
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "iviaruntime" {
  metadata {
    name      = "iviaruntime"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviaruntime" })
  }
  spec {
    selector = { app = "iviaruntime" }
    port {
      port        = 9443
      target_port = 9443
      name        = "iviaruntime"
      protocol    = "TCP"
    }
  }
}

#-------------------------------------------------------------------------------
# iviawrprp1 — Web Reverse Proxy rp1, browser-facing. ClusterIP + ALB Ingress.
# Sibling source: phase-a/ivia-eks.yaml:319-397.
#-------------------------------------------------------------------------------

resource "kubernetes_deployment" "iviawrprp1" {
  # Cannot reach Ready until autoconf creates the rp1 reverse-proxy instance.
  wait_for_rollout = false

  metadata {
    name      = "iviawrprp1"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviawrprp1" })
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "iviawrprp1" } }
    template {
      metadata { labels = { app = "iviawrprp1" } }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        volume {
          name = "iviaconfig"
          empty_dir {}
        }
        volume {
          name = "iviawrprp1-logs"
          empty_dir {}
        }

        container {
          name  = "iviawrprp1"
          image = "icr.io/ivia/ivia-wrp:11.0.2.0"

          port { container_port = 9443 }

          env {
            name  = "INSTANCE"
            value = "rp1"
          }
          env {
            name  = "CONTAINER_TIMEZONE"
            value = "Europe/London"
          }
          env {
            name  = "CONFIG_SERVICE_URL"
            value = "https://iviaconfig:9443/shared_volume"
          }
          env {
            name  = "CONFIG_SERVICE_USER_NAME"
            value = "cfgsvc"
          }
          env {
            name = "CONFIG_SERVICE_USER_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.configreader.metadata[0].name
                key  = "cfgsvcpw"
              }
            }
          }
          env {
            name  = "CONFIG_SERVICE_TLS_CACERT"
            value = "disabled"
          }

          volume_mount {
            name       = "iviaconfig"
            mount_path = "/var/shared"
          }
          volume_mount {
            name       = "iviawrprp1-logs"
            mount_path = "/var/application.logs"
          }

          readiness_probe {
            exec { command = ["/sbin/health_check.sh"] }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 2
          }
          liveness_probe {
            exec { command = ["/sbin/health_check.sh", "livenessProbe"] }
            period_seconds    = 10
            timeout_seconds   = 2
            failure_threshold = 6
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "iviawrprp1" {
  metadata {
    name      = "iviawrprp1"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviawrprp1" })
  }
  spec {
    selector = { app = "iviawrprp1" }
    port {
      port        = 9443
      target_port = 9443
      name        = "iviawrprp1"
      protocol    = "TCP"
    }
  }
}

#-------------------------------------------------------------------------------
# WRP ALB Ingress — browser-facing entry point for attendees. HTTP listener;
# backend protocol HTTPS (WRP serves 9443). Reuses target's annotation set.
# RESEARCH §2.11 reference.
#-------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "ivia_wrp" {
  wait_for_load_balancer = true
  metadata {
    name      = "ivia-wrp"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { app = "iviawrprp1" })
    annotations = {
      "alb.ingress.kubernetes.io/scheme"               = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"          = "ip"
      "alb.ingress.kubernetes.io/listen-ports"         = "[{\"HTTP\":80},{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/certificate-arn"      = var.tls_certificate_arn
      "alb.ingress.kubernetes.io/backend-protocol"     = "HTTPS"
      "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTPS"
      "alb.ingress.kubernetes.io/healthcheck-port"     = "9443"
      # Phase 07.8 Plan 02 (D-01): join the shared ALB IngressGroup so this
      # Ingress and the banking-UI Ingress (uc2_agent) co-tenant ONE ALB. Plan 03
      # cert-manager Certificate's HTTP-01 solver Ingress will land in the same
      # group with group.order=1 so /.well-known/acme-challenge/* wins before
      # this Ingress's /* catch-all (group.order=10).
      "alb.ingress.kubernetes.io/group.name"  = "workshop-acme"
      "alb.ingress.kubernetes.io/group.order" = "10"
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      # Phase 07.8 D-02: scope this Ingress to the nip.io WRP FQDN so the
      # shared workshop-acme ALB installs a host-discriminating rule. Without
      # this, both Ingresses default to host=* and the ALB's priority-1 rule
      # wins for ALL hostnames — see uc2_agent's banking-ui Ingress comment
      # for the redirect-loop trace. Pre-bootstrap fallback (empty
      # nip_io_wrp_host) leaves host=wildcard so the raw ALB hostname still
      # resolves during the bootstrap window.
      host = var.nip_io_wrp_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.iviawrprp1.metadata[0].name
              port { number = 9443 }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_service.iviawrprp1]
}

#-------------------------------------------------------------------------------
# base_layer ConfigMap — autoconf input. 7 text files (YAML + PEMs + lua).
# Mounted at /yaml in the Job's initContainer; copied to /merged then mounted
# at /base_layer in the autoconf container (RESEARCH §3.6 Approach C).
# Excludes the binary isvawrp.p12 — see kubernetes_secret.base_layer_p12 below.
#-------------------------------------------------------------------------------

resource "kubernetes_config_map" "base_layer" {
  metadata {
    name      = "ivia-base-layer"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  data = {
    # base_layer.yaml is now a template: ${wrp_alb_host} (the WRP ALB hostname,
    # resolvable here because the ingress sets wait_for_load_balancer=true),
    # ${runtime_user} (AAC runtime service user), and ${scim_bind_dn} (the SCIM
    # LDAP bind) are injected for the increment-2 MMFA subsystem. enable_mmfa_push
    # gates the push_notification_providers block: when no push API key is supplied
    # (var.ivia_mmfa_push_client_secret == "", the default) the block is omitted so
    # autoconf never tries to resolve the count-gated ivia-mmfa-push Secret (a
    # missing-secret !secret lookup fails the YAML load and aborts the whole run,
    # including the WebSEAL/forms-auth step).
    "base_layer.yaml" = templatefile("${path.module}/base_layer/base_layer.yaml.tftpl", {
      wrp_alb_host     = local.wrp_effective_host
      runtime_user     = local.ivia_runtime_user
      scim_bind_dn     = local.ivia_scim_bind_dn
      enable_mmfa_push = var.ivia_mmfa_push_client_secret != ""
    })
    # MMFA OAuth post-token mapping rule (IBM-shipped, verbatim). REQUIRED for
    # device enrollment — see api_protection note in base_layer.yaml.tftpl.
    "mmfa_oauth_posttoken_mapping.js" = file("${path.module}/base_layer/mmfa_oauth_posttoken_mapping.js")
    "ISAM-Trial-HashiCorp.cer"        = file("${path.module}/base_layer/ISAM-Trial-HashiCorp.cer")
    # Terraform-owned iviaop signing/serving cert (public half). Imported as an
    # lmi_trust_store signer so IVIA trusts the OIDC provider endpoint. State-derived
    # (was committed base_layer/iviaop.pem) — matches iviaop-config ConfigMap + outputs.
    "iviaop.pem" = tls_self_signed_cert.iviaop.cert_pem
    # Terraform-owned iviaruntime serving keypair. Minted into iviaruntime.p12 by
    # the autoconf job's bash preamble (Python cryptography lib), then imported
    # into LMI rt_profile_keys keystore as personal cert "server" (replacing the
    # Liberty-auto-generated cert of the same label). State-derived; survives all
    # pod restarts + module.ivia rebuilds via iviaconfig PVC.
    "iviaruntime.cert.pem" = tls_self_signed_cert.iviaruntime.cert_pem
    "iviaruntime.key.pem"  = tls_private_key.iviaruntime.private_key_pem
    # Terraform-owned iviawrprp1 (WRP) serving keypair — the autoconf preamble seals
    # these into iviawrprp1.p12 (mirrors the iviaruntime.p12 mint), replacing the
    # committed binary .p12. State-derived; identical cert every rebuild.
    "iviawrprp1.cert.pem"      = tls_self_signed_cert.iviawrprp1.cert_pem
    "iviawrprp1.key.pem"       = tls_private_key.iviawrprp1.private_key_pem
    "ldap.crt"                 = tls_self_signed_cert.openldap.cert_pem
    "DigiCertGlobalRootG3.crt" = file("${path.module}/base_layer/DigiCertGlobalRootG3.crt")
    "postgres.crt"             = tls_self_signed_cert.postgresql.cert_pem
    "req_openid_config.lua"    = file("${path.module}/base_layer/req_openid_config.lua")
    "rsp_openid_config.lua"    = file("${path.module}/base_layer/rsp_openid_config.lua")
  }
}

#-------------------------------------------------------------------------------
# base_layer binary Secret — now holds only the branded management-pages zip.
# iviawrprp1.p12 was removed (AWS security review): the WRP keypair is Terraform-
# owned and the .p12 is minted in-cluster by the autoconf preamble, so no binary
# private key ships in git. Kept as a Secret (not ConfigMap) since the initContainer
# copies both volumes into one flat /base_layer dir for the Python tool.
#-------------------------------------------------------------------------------

# OscarVault-branded WebSEAL management pages, zipped at plan time. The source
# tree (base_layer/management-pages/management/C/login.html) stays reviewable in
# git; archive_file produces the binary reverse_proxy.zip the WebSEAL
# `management_root` import expects (zip rooted at management/C/...). Output lands
# in a gitignored build dir, NOT under base_layer/ (would pollute the fileset).
data "archive_file" "ivia_management_pages" {
  type        = "zip"
  source_dir  = "${path.module}/base_layer/management-pages"
  output_path = "${path.module}/.terraform-build/reverse_proxy.zip"
}

resource "kubernetes_secret" "base_layer_p12" {
  metadata {
    name      = "ivia-base-layer-p12"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "Opaque"
  binary_data = {
    # Branded login page bundle — flat name matches `management_root` in
    # base_layer.yaml; the autoconf init container copies it into /base_layer.
    # (iviawrprp1.p12 is no longer here — minted at deploy from the TF keypair.)
    "reverse_proxy.zip" = filebase64(data.archive_file.ivia_management_pages.output_path)
  }
}

#-------------------------------------------------------------------------------
# autoconf Job — locals
# sha256 over the sorted file set of base_layer/. Used as a name suffix on the
# Job; any change to a base_layer/ file forces destroy+recreate of the Job
# (CONTEXT D2 — name-driven force-recreate). Combined with ttl=300 below,
# old Jobs auto-clean within 5 min of completion.
#-------------------------------------------------------------------------------

locals {
  # MMFA subsystem identities (increment 2). easuser = the AAC runtime's built-in
  # Liberty service user (IBM reference RUNTIME_USER). scim_bind_dn = the LDAP
  # bind the isamruntime SCIM connection uses. It MUST be the ISAM administrative
  # DN (cn=root,secAuthority=Default), NOT a least-privilege user: the SCIM
  # isam:1.0:User schema has update_native_users:True, so /scim/Me reads/writes
  # native IVIA security-entity data. A plain bind (we tried cn=iviascim) fails
  # the post-PATCH read-back with HPDAA0319E "insufficient access rights", which
  # blocks MMFA userPresenceMethods (Approve/Deny) self-enrollment. IBM's MMFA
  # autoconf reference binds wrp_runtime as cn=root,secAuthority=Default. Both are
  # fixed infrastructure service principals, not session-derived identities.
  ivia_runtime_user = "easuser"
  ivia_scim_bind_dn = "cn=root,secAuthority=Default"

  # Host that every MMFA endpoint URL in base_layer is rendered against. Phase
  # 07.8 Plan 05 re-wires this to var.nip_io_wrp_host (the nip.io FQDN the root
  # module parsed from .acme-state). On first deploy .acme-state is absent so
  # the variable is empty — the ternary falls back to the Ingress-status hostname
  # (the same self-signed-ELB path Plan 02 left in place) so the autoconf
  # base_layer always renders a resolvable host. After Plan 04's ACME step
  # writes .acme-state and re-applies module.ivia, this flips to the nip.io
  # FQDN, base_layer_hash recomputes, the autoconf Job re-runs, and IBM Verify
  # validates the LE-trusted chain during MMFA enrollment.
  wrp_effective_host = var.nip_io_wrp_host != "" ? var.nip_io_wrp_host : kubernetes_ingress_v1.ivia_wrp.status[0].load_balancer[0].ingress[0].hostname

  base_layer_files = sort(tolist(fileset("${path.module}/base_layer", "*")))
  base_layer_hash = sha256(join("", concat(
    [for f in local.base_layer_files : filesha256("${path.module}/base_layer/${f}")],
    # fileset("base_layer","*") is top-level only, so the management-pages/ subtree
    # is invisible to it. Fold in the zip's content hash so editing login.html
    # forces the autoconf Job to recreate and re-import the page.
    [data.archive_file.ivia_management_pages.output_sha256],
    # base_layer.yaml is now templated; ${wrp_alb_host} is resolved at apply time
    # and is NOT captured by filesha256 of the .tftpl source. Fold the rendered
    # host in so changing it (ELB hostname OR the public FQDN) re-renders the
    # ConfigMap and recreates the autoconf Job (re-running the MMFA wizard against
    # the new endpoints).
    [local.wrp_effective_host]
  )))
}

#-------------------------------------------------------------------------------
# ibmvia_autoconf Job — drives base_layer.yaml against the LMI REST API.
#
# Why in-cluster (NOT operator-side): ibmvia_autoconf's
# _restart_k8s_deployments handler reads the K8s downward-API namespace file
# at /var/run/secrets/kubernetes.io/serviceaccount/namespace. Outside a pod
# this raises RuntimeError (RESEARCH Pitfall 1, sibling base_layer.log:62-68).
# The Job must therefore run as a Pod with a ServiceAccount whose RBAC
# permits `_restart_k8s_deployments` (get/list/patch deployments).
#
# initContainer (busybox) merges the ConfigMap (text files) and Secret
# (binary P12) into a single emptyDir at /merged. Main container (python:3.11-slim)
# mounts /merged at /base_layer and runs `python -m ibmvia_autoconf`.
#
# RESEARCH §3 reference; LOCKED spec values from CONTEXT D2.
#-------------------------------------------------------------------------------

resource "kubernetes_job_v1" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf-${substr(local.base_layer_hash, 0, 8)}"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = merge(local.common_labels, { "app.kubernetes.io/name" = "ivia-autoconf" })
  }

  spec {
    # DEBUG: backoff_limit=0 + restart_policy=Never keeps failed pod around for inspection.
    # TODO: revert to backoff_limit=2 + restart_policy=OnFailure once autoconf is stable.
    backoff_limit              = 0
    active_deadline_seconds    = 1800
    ttl_seconds_after_finished = "86400"

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "ivia-autoconf" }
      }
      spec {
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account.ivia_autoconf.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.dockerlogin.metadata[0].name
        }

        volume {
          name = "config-merged"
          empty_dir {}
        }
        volume {
          name = "config-yaml"
          config_map {
            name = kubernetes_config_map.base_layer.metadata[0].name
          }
        }
        volume {
          name = "config-certs"
          secret {
            secret_name = kubernetes_secret.base_layer_p12.metadata[0].name
          }
        }

        init_container {
          name    = "merge-config"
          image   = "busybox:1.36"
          command = ["/bin/sh", "-c"]
          args    = ["cp /yaml/* /merged/ && cp /certs/* /merged/ && chmod -R 644 /merged/"]

          volume_mount {
            name       = "config-yaml"
            mount_path = "/yaml"
          }
          volume_mount {
            name       = "config-certs"
            mount_path = "/certs"
          }
          volume_mount {
            name       = "config-merged"
            mount_path = "/merged"
          }
        }

        container {
          name    = "autoconf"
          image   = "python:3.11-slim"
          command = ["/bin/sh", "-c"]
          args = [<<-EOSH
            set -e
            # autoconf 0.3.21 is the version aligned to our 11.0.2.0 appliance.
            # 0.3.22+ unconditionally pass the 11.0.3-only api_protection args
            # (definition_id/hash_secrets/max_active_secrets/min_secret_len) to
            # pyivia create_definition; on an 11.0.2.0 appliance pyivia maps to
            # APIProtection10030 which lacks those kwargs -> TypeError that blocks
            # MMFA enrollment. IBM has not shipped an 11.0.3.0 image (icr.io tops
            # out at 11.0.2.0), so the appliance can't be raised to match 0.3.34.
            # 0.3.21 still has the api_protection/mmfa/push_notifications handlers.
            # pyivia 0.2.44 stays (maps 11.0.2.0 -> 10030, compatible with 0.3.21).
            #
            # autoconf 0.3.21 hard-pins pyyaml==5.4.1 + Cython<3 in its metadata.
            # PyYAML 5.4.1 has no cp311 wheel, so pip builds it from sdist on this
            # python:3.11-slim image -- which (a) has no C compiler and (b) breaks
            # against Cython 3 ('build_ext' has no 'cython_sources'). We install
            # autoconf with --no-deps and supply its REAL runtime imports
            # ourselves: it only imports yaml/requests/pyivia/kubernetes (verified
            # in source). pyyaml 6.0.1 ships a cp311 manylinux wheel (no build) and
            # is API-compatible -- autoconf always calls yaml.load with an explicit
            # Loader (CustomLoader subclasses SafeLoader). The Cython/docker-compose/
            # typing metadata deps are never imported at runtime, so we skip them.
            pip install --quiet pyivia==0.2.44 kubernetes==31.0.0 requests pyyaml==6.0.1 cryptography
            pip install --quiet --no-deps ibmvia_autoconf==0.3.21
            # MINT iviaruntime.p12 from the Terraform-owned PEM cert+key (mounted into
            # /base_layer by the merge-config initContainer). The PKCS#12 file is what
            # LMI ssl_certificates POST /personal_cert expects — it cannot consume raw
            # PEM. Python's cryptography lib produces a PKCS#12 with no host-side
            # openssl needed (so the autoconf image stays python:3.11-slim). The .p12
            # is sealed with the random_password.ivia_runtime_p12_secret value, which
            # base_layer.yaml.tftpl references via `!secret verify-access/
            # ivia-runtime-p12-creds:secret` so autoconf unwraps with the matching pw.
            python - <<'PY'
            from cryptography.hazmat.primitives.serialization import (
                pkcs12, load_pem_private_key, BestAvailableEncryption,
            )
            from cryptography import x509
            import os
            base = "/base_layer"
            key = load_pem_private_key(open(f"{base}/iviaruntime.key.pem", "rb").read(), password=None)
            cert = x509.load_pem_x509_certificate(open(f"{base}/iviaruntime.cert.pem", "rb").read())
            p12 = pkcs12.serialize_key_and_certificates(
                name=b"server",
                key=key,
                cert=cert,
                cas=None,
                encryption_algorithm=BestAvailableEncryption(os.environ["IVIA_RUNTIME_P12_PASSWORD"].encode()),
            )
            # /base_layer is mounted read-only from the merged emptyDir; write under
            # /tmp and add to FILE_LOADER search by symlinking (autoconf resolves
            # p12_file via FILE_LOADER which already scans /tmp via OS default).
            out = "/tmp/iviaruntime.p12"
            open(out, "wb").write(p12)
            # Autoconf's FILE_LOADER.read_file resolves p12_file relative to
            # IVIA_CONFIG_BASE first; symlink into /base_layer is not possible (RO).
            # Workaround: set IVIA_CONFIG_BASE to a writable merged dir below.
            print(f"WROTE {out} ({len(p12)} bytes) sealed with random_password.ivia_runtime_p12_secret", flush=True)
            # MINT iviawrprp1.p12 the same way — replaces the committed binary .p12.
            # LMI imports it into pdsrv as personal cert "WRP" (base_layer.yaml.tftpl
            # personal_certificates[name=WRP].p12_file), sealed with the wrp-p12-creds
            # secret that base_layer.yaml unwraps via `!secret verify-access/wrp-p12-creds:secret`.
            wrp_key = load_pem_private_key(open(f"{base}/iviawrprp1.key.pem", "rb").read(), password=None)
            wrp_cert = x509.load_pem_x509_certificate(open(f"{base}/iviawrprp1.cert.pem", "rb").read())
            wrp_p12 = pkcs12.serialize_key_and_certificates(
                name=b"WRP",
                key=wrp_key,
                cert=wrp_cert,
                cas=None,
                encryption_algorithm=BestAvailableEncryption(os.environ["IVIA_WRP_P12_PASSWORD"].encode()),
            )
            wrp_out = "/tmp/iviawrprp1.p12"
            open(wrp_out, "wb").write(wrp_p12)
            print(f"WROTE {wrp_out} ({len(wrp_p12)} bytes) sealed with random_password.wrp_p12_secret", flush=True)
            PY
            # Stage a writable merged config dir so FILE_LOADER can resolve both the
            # ConfigMap-mounted files and the just-minted iviaruntime.p12.
            mkdir -p /tmp/base_layer
            cp -L /base_layer/* /tmp/base_layer/
            cp /tmp/iviaruntime.p12 /tmp/base_layer/
            cp /tmp/iviawrprp1.p12 /tmp/base_layer/
            chmod -R 644 /tmp/base_layer/
            # PATCH autoconf 0.3.21 push_notifications() idempotency bug (verified
            # against SDK source + the live API response). On the UPDATE path it
            # reads the existing provider id as old_pnp['pnr_id'], but the live
            # GET /iam/access/v8/push-notification returns that id under 'push_id'
            # -> KeyError 'pnr_id' crashes the whole run. Because aac.configure()
            # runs BEFORE web.configure() (configure.py), this crash ALSO blocks the
            # WebSEAL/forms-auth stanza step from ever executing. It additionally
            # matches existing providers on app_id alone, but our apple+android
            # providers share one app_id -> both updates would target the same entry
            # and corrupt one. Fix: match on app_id+platform and use push_id (with a
            # pnr_id fallback). Guarded marker = idempotent; fail-loud if source drifts.
            python - <<'PY'
            import sys
            p = "/usr/local/lib/python3.11/site-packages/ibmvia_autoconf/access_control.py"
            s = open(p).read()
            if "provider.platform" in s:
                print("autoconf push_notifications already patched; skipping", flush=True); sys.exit(0)
            old1 = "old_pnp = optional_list(filter_list('app_id', provider.app_id, existing_pnp))[0]"
            new1 = "old_pnp = optional_list(filter_list('platform', provider.platform, filter_list('app_id', provider.app_id, existing_pnp)))[0]"
            old2 = "self.aac.push_notification.update_provider(old_pnp['pnr_id'], **provider)"
            new2 = "self.aac.push_notification.update_provider(old_pnp.get('push_id') or old_pnp.get('pnr_id'), **provider)"
            for needle in (old1, old2):
                if needle not in s:
                    print("FATAL: expected autoconf push_notifications source not found; refusing to run unpatched", flush=True); sys.exit(3)
            open(p, "w").write(s.replace(old1, new1).replace(old2, new2))
            print("PATCHED autoconf push_notifications: match app_id+platform, use push_id (fixes KeyError pnr_id)", flush=True)
            PY
            # PATCH autoconf 0.3.21 _import_personal_cert to DELETE existing label
            # before import. pyivia ssl_certificates.import_personal does not have
            # replace semantics — the LMI returns an error if the label already
            # exists, and autoconf does not delete-first. For rt_profile_keys the
            # "server" label is auto-populated by Liberty on every iviaruntime cold
            # start, so we MUST delete-then-import to install the Terraform-owned
            # cert. Tolerates 404 (first-install path). RESTClient.delete already
            # exists in pyivia (restclient.py:37); we drive it directly because
            # sslcertificates.py does not expose delete_personal. Guarded marker
            # = idempotent.
            python - <<'PY'
            import sys
            p = "/usr/local/lib/python3.11/site-packages/ibmvia_autoconf/configure.py"
            s = open(p).read()
            if "_TF_DELETE_BEFORE_IMPORT" in s:
                print("autoconf _import_personal_cert delete-then-import patch already applied; skipping", flush=True); sys.exit(0)
            old = "    def _import_personal_cert(self, db_name, cert):\n        ssl = self.factory.get_system_settings().ssl_certificates\n        personal_parsed_file = optional_list(FILE_LOADER.read_file(cert.p12_file))[0]\n        rsp = ssl.import_personal(db_name, "
            new = (
                "    def _import_personal_cert(self, db_name, cert):  # _TF_DELETE_BEFORE_IMPORT\n"
                "        ssl = self.factory.get_system_settings().ssl_certificates\n"
                "        personal_parsed_file = optional_list(FILE_LOADER.read_file(cert.p12_file))[0]\n"
                "        # Pre-step: DELETE existing personal cert with this label. Tolerates 404.\n"
                "        # LMI rejects re-import of an existing label; replace semantics requires\n"
                "        # delete-then-import.\n"
                "        if cert.name:\n"
                "            del_endpoint = '/isam/ssl_certificates/{}/personal_cert/{}'.format(db_name, cert.name)\n"
                "            # Accept: application/json MUST be passed explicitly — pyivia\n"
                "            # RESTClient.delete defaults to */* which routes through the LMI\n"
                "            # HTML web UI handler (returns 405). The JSON REST handler returns\n"
                "            # 200 on success / 404 on missing label.\n"
                "            del_rsp = ssl._client.delete(del_endpoint, accept_type='application/json')\n"
                "            if del_rsp.status_code in (200, 204):\n"
                "                _logger.info('Deleted existing personal cert {} from {} before import'.format(cert.name, db_name))\n"
                "            elif del_rsp.status_code == 404:\n"
                "                _logger.info('No existing personal cert {} in {} to delete (first install)'.format(cert.name, db_name))\n"
                "            else:\n"
                "                _logger.error('Pre-import delete returned status {} for {}/{}: {}'.format(del_rsp.status_code, db_name, cert.name, getattr(del_rsp, 'data', '')))\n"
                "        rsp = ssl.import_personal(db_name, "
            )
            if old not in s:
                print("FATAL: expected autoconf _import_personal_cert source not found; refusing to run unpatched", flush=True); sys.exit(3)
            open(p, "w").write(s.replace(old, new))
            print("PATCHED autoconf _import_personal_cert: DELETE existing label before LMI import", flush=True)
            PY
            cd /tmp/base_layer
            IVIA_CONFIG_YAML=base_layer.yaml \
            IVIA_CONFIG_BASE=/tmp/base_layer \
            IVIA_MGMT_BASE_URL=https://iviaconfig.verify-access.svc.cluster.local:9443 \
            IVIA_MGMT_USER=admin \
            IVIA_MGMT_OLD_PWD="$ADMIN_PWD" \
            IVIA_MGMT_PWD="$ADMIN_PWD" \
            python -m ibmvia_autoconf
          EOSH
          ]

          env {
            name = "ADMIN_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_admin.metadata[0].name
                key  = "adminpw"
              }
            }
          }

          # PKCS#12 seal password for the in-cluster-minted iviaruntime.p12. Must
          # equal kubernetes_secret.ivia_runtime_p12_creds.data.secret so the
          # `!secret verify-access/ivia-runtime-p12-creds:secret` lookup in
          # base_layer.yaml.tftpl resolves to the same value autoconf gives the
          # LMI for the cert-unwrap step.
          env {
            name = "IVIA_RUNTIME_P12_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_runtime_p12_creds.metadata[0].name
                key  = "secret"
              }
            }
          }

          # PKCS#12 seal password for the in-cluster-minted iviawrprp1.p12. Must
          # equal kubernetes_secret.wrp_p12_creds.data.secret so the `!secret
          # verify-access/wrp-p12-creds:secret` lookup in base_layer.yaml.tftpl
          # resolves to the same value autoconf gives LMI for the WRP cert import.
          env {
            name = "IVIA_WRP_P12_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.wrp_p12_creds.metadata[0].name
                key  = "secret"
              }
            }
          }

          volume_mount {
            name       = "config-merged"
            mount_path = "/base_layer"
            read_only  = true
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "30m"
  }

  depends_on = [
    kubernetes_deployment.iviaconfig,
    kubernetes_service.iviaconfig,
    kubernetes_deployment.openldap,
    kubernetes_service.openldap,
    kubernetes_deployment.postgresql,
    kubernetes_service.postgresql,
    kubernetes_deployment.iviadsc,
    kubernetes_service.iviadsc,
    kubernetes_deployment.iviaop,
    kubernetes_service.iviaop,
    kubernetes_deployment.iviaruntime,
    kubernetes_service.iviaruntime,
    kubernetes_deployment.iviawrprp1,
    kubernetes_service.iviawrprp1,
    kubernetes_role_binding.ivia_autoconf,
    kubernetes_secret.configreader,
    kubernetes_secret.wrp_p12_creds,
    kubernetes_secret.ivia_runtime_p12_creds,
    kubernetes_secret.postgresql_creds,
    kubernetes_secret.openldap_creds,
    kubernetes_secret.ivia_secauthority_creds,
    # MMFA subsystem credentials (increment 2) — must exist before autoconf
    # resolves their !secret references (runtime service user + SCIM LDAP bind).
    kubernetes_secret.ivia_runtime_user,
    kubernetes_secret.ivia_scim_bind,
    kubernetes_config_map.base_layer,
    kubernetes_secret.base_layer_p12,
    # MMFA push credential (count-gated; empty list when not configured). Ensures
    # the secret exists before autoconf reads it via !secret in a later increment.
    kubernetes_secret.ivia_mmfa_push,
  ]
}

