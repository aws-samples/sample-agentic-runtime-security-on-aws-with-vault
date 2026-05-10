################################################################################
# Verify Access Module — Main
# IBM Verify Identity Access OIDC Provider (image tag 26.03)
#
# Deploys IVIA via raw kubernetes_* Terraform resources (no Helm chart exists
# for IVIA). Provides OAuth client_credentials grant as the identity plane
# for workload-identity delegation. Vault jwt auth (Plan 03-03) consumes the
# OIDC discovery URL output.
#
# Config structure follows IBM official docs:
#   https://docs.verify.ibm.com/ibm-security-verify-access/docs/configuration
#   https://github.com/IBM-Security/verify-access-oidc-provider-resources
#
# Key design decisions:
#   - Inline B64 keystore in config.yaml (avoids projected-volume complexity)
#   - secret: K8s API syntax for DB creds + obf key (RBAC already granted)
#   - Config stored in kubernetes_secret (contains B64-encoded private key)
#   - DB schema initialized via kubernetes_job before deployment
#
# Pitfall 3: ICR pull secret MUST be created before deployment — without it
#            pods get ImagePullBackOff (icr.io/ivia/ivia-oidc-provider:26.03).
# Pitfall 6: Use raw kubernetes_* resources only. The kubernetes provider is
#            already pinned in the stack; no extra provider is needed.
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

################################################################################
# Data Sources
################################################################################

# Fetch RDS master password from Secrets Manager.
# Secret value is JSON: {"username": "vault_root", "password": "<generated>"}
data "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = var.rds_master_user_secret_arn
}

locals {
  rds_creds = jsondecode(data.aws_secretsmanager_secret_version.rds_master.secret_string)

  # Base64-encode TLS material for inline keystore in config.yaml.
  # The B64: prefix tells IVIA to decode at runtime.
  server_key_b64  = base64encode(tls_private_key.isvaop.private_key_pem)
  server_cert_b64 = base64encode(tls_self_signed_cert.isvaop.cert_pem)
}

################################################################################
# Random Resources
################################################################################

# IVIA obfuscation key — used to protect sensitive configuration values stored
# in the runtime database (standard IVIA security practice).
resource "random_password" "obfuscation_key" {
  length  = 32
  special = false
}

# Client secret for the workshop OIDC client (client_credentials grant).
resource "random_password" "client_secret" {
  length  = 32
  special = false
}

################################################################################
# TLS — Self-signed certificate for IVIA OIDC provider (workshop only)
# Production would use cert-manager with a real CA.
################################################################################

resource "tls_private_key" "isvaop" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "isvaop" {
  private_key_pem = tls_private_key.isvaop.private_key_pem

  subject {
    common_name  = "isvaop.verify-access.svc.cluster.local"
    organization = "Workshop"
  }

  dns_names = [
    "isvaop",
    "isvaop.verify-access",
    "isvaop.verify-access.svc",
    "isvaop.verify-access.svc.cluster.local",
  ]

  validity_period_hours = 8760
  is_ca_certificate     = false

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

################################################################################
# Kubernetes Namespace
################################################################################

resource "kubernetes_namespace" "verify_access" {
  metadata {
    name = "verify-access"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "workshop/component"           = "ivia"
    }
  }
}

################################################################################
# ICR Pull Secret (Pitfall 3)
# Without this K8s secret, the isvaop pod cannot pull from icr.io and will
# enter ImagePullBackOff. The IBM entitlement key is the password for user
# "iamapikey" against the registry.
################################################################################

resource "kubernetes_secret" "icr_pull" {
  metadata {
    name      = "icr-pull-secret"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
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

################################################################################
# Service Account + RBAC
# RBAC grants get/list/watch on secrets and configmaps — REQUIRED for the
# secret: K8s API reference syntax used in config.yaml.
################################################################################

resource "kubernetes_service_account" "isvaop" {
  metadata {
    name      = "isvaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  image_pull_secret {
    name = kubernetes_secret.icr_pull.metadata[0].name
  }
}

resource "kubernetes_role" "isvaop" {
  metadata {
    name      = "isvaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "isvaop" {
  metadata {
    name      = "isvaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.isvaop.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.isvaop.metadata[0].name
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }
}

################################################################################
# Kubernetes Secrets
################################################################################

# PostgreSQL connection details — bootstrap only.
# Vault rotates the master credential post-deploy and vends short-lived
# per-role creds at runtime (Phase 3 Plan 03 vault_config).
# IVIA reads these via secret:isvaop-server/<key> K8s API syntax.
resource "kubernetes_secret" "isvaop_server" {
  metadata {
    name      = "isvaop-server"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    host     = var.rds_address
    port     = tostring(var.rds_port)
    username = local.rds_creds["username"]
    password = local.rds_creds["password"]
    database = var.rds_db_name
  }
}

# IVIA obfuscation key — protects sensitive config at rest in the runtime DB.
# IVIA reads via secret:isvaop-obf/obfuscation_key K8s API syntax.
resource "kubernetes_secret" "isvaop_obf" {
  metadata {
    name      = "isvaop-obf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    obfuscation_key = random_password.obfuscation_key.result
  }
}

################################################################################
# Config — IVIA Main Configuration
# Uses kubernetes_config_map (not kubernetes_secret) to avoid the Kubernetes
# provider identity bug that hits secrets on updates in Terraform Stacks.
# NOTE: config.yaml contains B64-encoded key material but config maps are
# adequate for workshop use (same cluster-internal security boundary).
# Mounted at /var/isvaop/config — the only volume mount needed.
################################################################################

locals {
  activation_code_b64 = join("", [for line in split("\n", var.ivia_activation_code) : trimspace(line) if !startswith(trimspace(line), "-----") && length(trimspace(line)) > 0])

  isvaop_config_yaml = <<-EOT
version: 24.08

server:
  activation_code: "${local.activation_code_b64}"
  ssl:
    key: "ks:https_keys/serverkey"
    certificate: "ks:https_keys/servercert"

secrets:
  obf_key: "secret:isvaop-obf/obfuscation_key"

definition:
  id: 1
  name: "Workshop OIDC"
  grant_types:
    - client_credentials
  access_policy_id: allow_all
  pre_mappingrule_id: pretoken
  post_mappingrule_id: posttoken
  base_url: "https://isvaop.verify-access.svc.cluster.local:8436"
  token_settings:
    issuer: "https://isvaop.verify-access.svc.cluster.local:8436"
    signing_alg: RS256
    signing_keystore: https_keys
    signing_keylabel: serverkey
    access_token_lifetime: 900
    id_token_lifetime: 3600

jwks:
  signing_keystore: https_keys

runtime_db: workshopdb

session_cache:
  type: db

server_connections:
  - name: workshopdb
    type: postgresql
    database_name: "secret:isvaop-server/database"
    hosts:
      - hostname: "secret:isvaop-server/host"
        hostport: "secret:isvaop-server/port"
    credential:
      username: "secret:isvaop-server/username"
      password: "secret:isvaop-server/password"
    ssl_settings:
      use_ssl: false

rules:
  access_policy:
    - name: allow_all
      content: |
        context.setDecision(Decision.allow());
  mapping:
    - name: pretoken
      rule_type: javascript
      content: |
        // No enrichment needed for workshop
    - name: posttoken
      rule_type: javascript
      content: |
        // No post-processing needed for workshop

clients:
  - client_id: workshop_agent
    client_secret: "${random_password.client_secret.result}"
    client_name: "Workshop Agent Client"
    enabled: true
    grant_types:
      - client_credentials
    token_endpoint_auth_method: client_secret_basic
    id_token_signed_response_alg: RS256

keystore:
  - name: https_keys
    type: pem
    certificate:
      - label: servercert
        content: "B64:${local.server_cert_b64}"
    key:
      - label: serverkey
        content: "B64:${local.server_key_b64}"

logging:
  level: info
EOT

  isvaop_config_hash = sha256(local.isvaop_config_yaml)
}

resource "kubernetes_config_map" "isvaop_config_data" {
  metadata {
    name      = "isvaop-cfg-data"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
    annotations = {
      "config-hash" = local.isvaop_config_hash
    }
  }

  data = {
    "config.yaml" = local.isvaop_config_yaml
  }
}

################################################################################
# DB Schema Initialization Job
# IVIA does NOT auto-create database tables. Without the schema, the container
# terminates at startup. This job runs the cumulative schema SQL (base +
# updates through 25.10) idempotently before the IVIA deployment starts.
#
# Source: https://github.com/IBM-Security/verify-access-oidc-provider-resources/
#         tree/master/resources/db/pg
################################################################################

resource "kubernetes_job" "ivia_db_init" {
  metadata {
    name      = "ivia-db-init"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-db-init"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "ivia-db-init"
        }
      }

      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.isvaop.metadata[0].name

        container {
          name  = "db-init"
          image = "public.ecr.aws/docker/library/postgres:17-alpine"

          env {
            name = "PGHOST"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.isvaop_server.metadata[0].name
                key  = "host"
              }
            }
          }

          env {
            name = "PGPORT"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.isvaop_server.metadata[0].name
                key  = "port"
              }
            }
          }

          env {
            name = "PGUSER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.isvaop_server.metadata[0].name
                key  = "username"
              }
            }
          }

          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.isvaop_server.metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            name = "PGDATABASE"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.isvaop_server.metadata[0].name
                key  = "database"
              }
            }
          }

          command = ["/bin/sh", "-c"]
          args = [<<-EOSQL
            psql -v ON_ERROR_STOP=0 <<'SQL'
            -- ================================================================
            -- IVIA Cumulative Schema (base 0.0.1 + 24.12 + 25.10)
            -- All statements are idempotent (CREATE IF NOT EXISTS / DO blocks)
            -- Source: IBM-Security/verify-access-oidc-provider-resources
            -- ================================================================

            -- Token/session storage
            CREATE TABLE IF NOT EXISTS OAUTH20_TOKEN_CACHE (
                LOOKUP_ID         VARCHAR(256) NOT NULL PRIMARY KEY,
                UNIQUEID          VARCHAR(128) NOT NULL,
                COMPONENTID       VARCHAR(256) NOT NULL,
                TYPE              VARCHAR(64)  NOT NULL,
                SUBTYPE           VARCHAR(64),
                CREATEDAT         BIGINT       NOT NULL,
                LIFETIME          INT          NOT NULL,
                EXPIRES           BIGINT       NOT NULL,
                TOKENSTRING       TEXT         NOT NULL,
                CLIENTID          VARCHAR(256) NOT NULL,
                USERNAME          VARCHAR(256),
                SCOPE             VARCHAR(512),
                REDIRECTURI       VARCHAR(2048),
                STATEID           VARCHAR(256),
                EXTENDEDFIELDS    TEXT
            );

            -- SESSION_ID column (added in 25.10)
            DO $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name = 'oauth20_token_cache'
                  AND column_name = 'session_id'
              ) THEN
                ALTER TABLE OAUTH20_TOKEN_CACHE ADD COLUMN SESSION_ID VARCHAR(256);
              END IF;
            END $$;

            -- Extended token attributes
            CREATE TABLE IF NOT EXISTS OAUTH20_TOKEN_EXTRA_ATTRIBUTE (
                ID                SERIAL       PRIMARY KEY,
                LOOKUP_ID         VARCHAR(256) NOT NULL,
                ATTR_NAME         VARCHAR(256) NOT NULL,
                ATTR_VALUE        VARCHAR(1024)
            );

            -- JWT ID replay protection
            CREATE TABLE IF NOT EXISTS OAUTH20_JTI (
                ID                SERIAL       PRIMARY KEY,
                JTI               VARCHAR(512) NOT NULL UNIQUE,
                EXPIRES           BIGINT       NOT NULL
            );

            -- Consent / trusted client records
            CREATE TABLE IF NOT EXISTS OAUTH_TRUSTED_CLIENT (
                ID                SERIAL       PRIMARY KEY,
                USERNAME          VARCHAR(256) NOT NULL,
                CLIENTID          VARCHAR(256) NOT NULL,
                CREATEDAT         BIGINT       NOT NULL,
                UNIQUE (USERNAME, CLIENTID)
            );

            -- Scope grants (FK to OAUTH_TRUSTED_CLIENT)
            CREATE TABLE IF NOT EXISTS OAUTH_SCOPE (
                ID                SERIAL       PRIMARY KEY,
                TRUSTED_CLIENT_ID INT          NOT NULL REFERENCES OAUTH_TRUSTED_CLIENT(ID) ON DELETE CASCADE,
                SCOPE             VARCHAR(256) NOT NULL
            );

            -- RAR authorization details (added in 24.12)
            CREATE TABLE IF NOT EXISTS OAUTH_AUTHORIZATION_DETAILS (
                ID                SERIAL       PRIMARY KEY,
                TRUSTED_CLIENT_ID INT          NOT NULL REFERENCES OAUTH_TRUSTED_CLIENT(ID) ON DELETE CASCADE,
                TYPE              VARCHAR(256) NOT NULL,
                DETAILS           TEXT
            );

            -- Dynamic client registration
            CREATE TABLE IF NOT EXISTS OAUTH20_DYNAMIC_CLIENT (
                CLIENTID          VARCHAR(256) NOT NULL PRIMARY KEY,
                COMPONENTID       VARCHAR(256) NOT NULL,
                CLIENTMETADATA    TEXT         NOT NULL,
                CREATEDAT         BIGINT       NOT NULL,
                UPDATEDAT         BIGINT
            );

            -- General key-value store with TTL
            CREATE TABLE IF NOT EXISTS DMAP_ENTRIES (
                KEY               VARCHAR(512) NOT NULL PRIMARY KEY,
                VALUE             TEXT,
                DATATYPE          VARCHAR(64),
                EXPIRY            BIGINT
            );

            -- Indexes for performance
            CREATE INDEX IF NOT EXISTS IDX_TOKEN_CACHE_EXPIRES
              ON OAUTH20_TOKEN_CACHE (EXPIRES);
            CREATE INDEX IF NOT EXISTS IDX_TOKEN_CACHE_CLIENTID
              ON OAUTH20_TOKEN_CACHE (CLIENTID);
            CREATE INDEX IF NOT EXISTS IDX_TOKEN_EXTRA_LOOKUP
              ON OAUTH20_TOKEN_EXTRA_ATTRIBUTE (LOOKUP_ID);
            CREATE INDEX IF NOT EXISTS IDX_JTI_EXPIRES
              ON OAUTH20_JTI (EXPIRES);
            CREATE INDEX IF NOT EXISTS IDX_DMAP_EXPIRY
              ON DMAP_ENTRIES (EXPIRY);

            SQL
            echo "IVIA database schema initialized successfully"
          EOSQL
          ]

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
  }

  depends_on = [
    kubernetes_secret.isvaop_server,
  ]
}

################################################################################
# Deployment
################################################################################

resource "kubernetes_deployment" "isvaop" {
  metadata {
    name      = "isvaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/version"    = "26.03"
      "app.kubernetes.io/managed-by" = "terraform"
      "workshop/component"           = "ivia"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "isvaop"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "isvaop"
          "app.kubernetes.io/version" = "26.03"
          "workshop/component"        = "ivia"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.isvaop.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.icr_pull.metadata[0].name
        }

        container {
          name  = "isvaop"
          image = "icr.io/ivia/ivia-oidc-provider:26.03"

          port {
            container_port = 8436
            name           = "oidc-https"
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
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
            failure_threshold     = 6
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
            failure_threshold     = 3
          }

          # Single volume mount — config secret contains config.yaml with
          # inline B64 keystore. IVIA reads DB creds and obf key via K8s API
          # (secret: syntax), so no additional volume mounts are needed.
          volume_mount {
            name       = "config"
            mount_path = "/var/isvaop/config"
            read_only  = true
          }

          volume_mount {
            name       = "schema-rar"
            mount_path = "/isvaop/config/schema/rar"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.isvaop_config_data.metadata[0].name
            items {
              key  = "config.yaml"
              path = "config.yaml"
            }
          }
        }

        volume {
          name = "schema-rar"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret.icr_pull,
    kubernetes_secret.isvaop_server,
    kubernetes_secret.isvaop_obf,
    kubernetes_config_map.isvaop_config_data,
    kubernetes_job.ivia_db_init,
  ]
}

################################################################################
# Service — ClusterIP (internal OIDC access for Vault jwt auth)
################################################################################

resource "kubernetes_service" "isvaop" {
  metadata {
    name      = "isvaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "isvaop"
    }

    type = "ClusterIP"

    port {
      name        = "oidc-https"
      port        = 8436
      target_port = 8436
      protocol    = "TCP"
    }
  }
}

################################################################################
# Ingress — ALB via AWS Load Balancer Controller (external OIDC discovery)
################################################################################

resource "kubernetes_ingress_v1" "isvaop" {
  metadata {
    name      = "isvaop"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/managed-by" = "terraform"
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
              name = kubernetes_service.isvaop.metadata[0].name
              port {
                number = 8436
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service.isvaop]
}
