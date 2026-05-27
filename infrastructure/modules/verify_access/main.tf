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
    "iviaop.key"     = file("${path.module}/iviaop-config/iviaop.key")
    "iviaop.pem"     = file("${path.module}/iviaop-config/iviaop.pem")
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
          "checksum/iviaop-config" = sha256(jsonencode(kubernetes_config_map.iviaop_config.data))
        }
      }
      spec {
        image_pull_secrets { name = kubernetes_secret.dockerlogin.metadata[0].name }

        volume {
          name = "iviaop-config"
          config_map {
            name = kubernetes_config_map.iviaop_config.metadata[0].name
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
      "alb.ingress.kubernetes.io/ssl-redirect"         = "443"
      "alb.ingress.kubernetes.io/backend-protocol"     = "HTTPS"
      "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTPS"
      "alb.ingress.kubernetes.io/healthcheck-port"     = "9443"
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
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
    "base_layer.yaml"          = file("${path.module}/base_layer/base_layer.yaml")
    "ISAM-Trial-HashiCorp.cer" = file("${path.module}/base_layer/ISAM-Trial-HashiCorp.cer")
    "iviaop.pem"               = file("${path.module}/base_layer/iviaop.pem")
    "ldap.crt"                 = file("${path.module}/base_layer/ldap.crt")
    "postgres.crt"             = tls_self_signed_cert.postgresql.cert_pem
    "req_openid_config.lua"    = file("${path.module}/base_layer/req_openid_config.lua")
    "rsp_openid_config.lua"    = file("${path.module}/base_layer/rsp_openid_config.lua")
  }
}

#-------------------------------------------------------------------------------
# base_layer P12 Secret — isvawrp.p12 is binary PKCS#12 with a private key.
# Separated from the ConfigMap to keep binary bytes via binary_data and
# private-key material in a Secret rather than a ConfigMap. The initContainer
# in the autoconf Job copies both volumes into the merged emptyDir so the
# Python tool sees one flat /base_layer directory.
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
    "iviawrprp1.p12" = filebase64("${path.module}/base_layer/iviawrprp1.p12")
    # Branded login page bundle — flat name matches `management_root` in
    # base_layer.yaml; the autoconf init container copies it into /base_layer.
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
  base_layer_files = sort(tolist(fileset("${path.module}/base_layer", "*")))
  base_layer_hash = sha256(join("", concat(
    [for f in local.base_layer_files : filesha256("${path.module}/base_layer/${f}")],
    # fileset("base_layer","*") is top-level only, so the management-pages/ subtree
    # is invisible to it. Fold in the zip's content hash so editing login.html
    # forces the autoconf Job to recreate and re-import the page.
    [data.archive_file.ivia_management_pages.output_sha256]
  )))
}

#-------------------------------------------------------------------------------
# ibmvia_autoconf Job — drives base_layer.yaml against the LMI REST API.
#
# Why in-cluster (NOT operator-side): ibmvia_autoconf 0.3.34's
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
            pip install --quiet ibmvia_autoconf==0.3.34 pyivia==0.2.44 kubernetes==31.0.0
            cd /base_layer
            IVIA_CONFIG_YAML=base_layer.yaml \
            IVIA_CONFIG_BASE=/base_layer \
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
    kubernetes_secret.postgresql_creds,
    kubernetes_secret.openldap_creds,
    kubernetes_secret.ivia_secauthority_creds,
    kubernetes_config_map.base_layer,
    kubernetes_secret.base_layer_p12,
  ]
}

