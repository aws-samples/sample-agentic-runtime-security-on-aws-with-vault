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
#   - In-cluster kubernetes_job_v1 running python -m ibmvia_autoconf 0.3.34
#     against a MINIMAL webseal.runtime base_layer.yaml.
#   - LMI external exposure via NLB Service (TCP passthrough on 9443).
#   - WRP browser exposure via existing ALB Ingress (separate path).
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
# Cross-node LDAPS (TCP/636). pdconfig running on iviaruntime pod may schedule
# on a different node than the openldap pod; the EKS node SG default ingress
# rules do not include TCP/636 between same-SG nodes. Source = same SG (self).
# Sibling reference: phase-a/03-ivia-deploy.sh:23-30. Pattern matches target's
# existing modules/rds/main.tf:54-72.
#-------------------------------------------------------------------------------

resource "aws_security_group_rule" "node_ldaps_self" {
  type                     = "ingress"
  from_port                = 636
  to_port                  = 636
  protocol                 = "tcp"
  security_group_id        = var.node_security_group_id
  source_security_group_id = var.node_security_group_id
  description              = "IVIA pdconfig: cross-node LDAPS from iviaruntime to openldap pod (sibling 03-ivia-deploy.sh:24-30)"
}

#-------------------------------------------------------------------------------
# RBAC for the autoconf Job. ibmvia_autoconf 0.3.34 requires:
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

resource "random_password" "cfgsvc_pwd" {
  length  = 24
  special = false
}

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

resource "random_password" "sec_master_pwd" {
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
    cfgsvcpw = random_password.cfgsvc_pwd.result
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
  # Use binary_data — dhparam.pem and the certs are PEM ASCII but we treat
  # the bundle as a binary blob to avoid any newline/encoding surprises.
  binary_data = {
    "ldap.crt"    = filebase64("${path.module}/base_layer/openldap-keys/ldap.crt")
    "ldap.key"    = filebase64("${path.module}/base_layer/openldap-keys/ldap.key")
    "ca.crt"      = filebase64("${path.module}/base_layer/openldap-keys/ca.crt")
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
    # Sibling's isvawrp.p12 is exported with passout 'Passw0rd' (common/create-ivia-pki.sh:36).
    # Since we commit the P12 verbatim, base_layer.yaml's `secret:` value MUST be
    # the same string the P12 was wrapped with: "Passw0rd". When we later
    # regenerate the P12 (post-Phase 7), this random_password will drive the
    # passout. For now, override with the sibling-locked string.
    # CONTEXT D4 documented exception.
    secret = "Passw0rd"
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
