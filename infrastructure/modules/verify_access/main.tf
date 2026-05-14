################################################################################
# Verify Access Module — Main
# IBM Verify Identity Access OIDC Provider (image tag 25.10)
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
#            pods get ImagePullBackOff (icr.io/ivia/ivia-oidc-provider:25.10).
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
      version = "~> 2.35"
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

# IVIA Config container admin password. Set as ADMIN_PWD env var on the Config
# container (port 9443 LMI). Also injected into the autoconf job.
resource "random_password" "ivia_admin_pwd" {
  length  = 24
  special = false
}

# cfgsvc password used by worker containers (WRP, Runtime) to pull snapshots
# from the Config container via CONFIG_SERVICE_URL. Must match the password
# set in the Config container LMI for the cfgsvc user.
resource "random_password" "configreader_pwd" {
  length  = 24
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

resource "kubernetes_secret" "isvaop_ldap" {
  metadata {
    name      = "isvaop-ldap"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "isvaop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    bind_password = var.simple_ad_admin_password
  }
}

################################################################################
# Config — IVIA Main Configuration
# Mounted at /var/isvaop/config — the only volume mount needed.
################################################################################

locals {
  simple_ad_ldap_hosts = join("\n", [
    for ip in var.simple_ad_dns_ips : "      - hostname: \"${ip}\"\n        hostport: 389"
  ])

  isvaop_config_yaml = <<-EOT
version: 24.08

server:
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
    - authorization_code
    - refresh_token
    - password
    - urn:openid:params:grant-type:ciba
    - urn:ietf:params:oauth:grant-type:token-exchange
  authorization_details_types_supported:
    - type: refund_approval
      strategy: default
  access_policy_id: allow_all
  pre_mappingrule_id: pretoken
  post_mappingrule_id: posttoken
  base_url: "http://${try(kubernetes_ingress_v1.ivia_wrp.status[0].load_balancer[0].ingress[0].hostname, "")}/isvaop"
  token_settings:
    issuer: "http://${try(kubernetes_ingress_v1.ivia_wrp.status[0].load_balancer[0].ingress[0].hostname, "")}/isvaop"
    signing_alg: RS256
    signing_keystore: https_keys
    signing_keylabel: serverkey
    access_token_lifetime: 900
    id_token_lifetime: 3600
  attribute_map:
    sub: ldap_sub
    email: ldap_email
    name: ldap_name

authentication:
  # WRP internal ClusterIP auth endpoint — OIDC Provider calls WRP server-side
  # to initiate authentication before redirecting the browser. WRP then serves
  # the login page and forwards the authenticated session back through /isvaop.
  # TODO: Validate this path against IVIA WRP junction config on live deployment.
  endpoint: "https://iviawrp.verify-access.svc.cluster.local:9443/mga/sps/oauth/oauth20/authorize"
  callback_param_name: Target
  subject_attribute_name: sAMAccountName

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
  - name: simple_ad
    type: ldap
    hosts:
${local.simple_ad_ldap_hosts}
    credential:
      bind_dn: "${var.simple_ad_bind_dn}"
      bind_password: "secret:isvaop-ldap/bind_password"
    conn_settings:
      max_pool_size: 10
      connect_timeout: 5

ldapcfg:
  - name: workshop_users
    user_object_classes: "top,person,organizationalPerson,user"
    filter: "(&(objectClass=user)(!(objectClass=computer)))"
    selector: "objectClass,cn,sAMAccountName,userPrincipalName,displayName,givenName,sn,mail"
    srv_conn: simple_ad
    attribute: sAMAccountName
    baseDN: "${var.simple_ad_base_dn}"

attribute_sources:
  - id: 1
    name: ldap_sub
    type: ldap
    value: sAMAccountName
    scope: subtree
    filter: "(&(objectClass=user)(sAMAccountName={AZN_CRED_PRINCIPAL_NAME}))"
    selector: "sAMAccountName"
    srv_conn: simple_ad
    baseDN: "${var.simple_ad_base_dn}"
  - id: 2
    name: ldap_email
    type: ldap
    value: mail
    scope: subtree
    filter: "(&(objectClass=user)(sAMAccountName={AZN_CRED_PRINCIPAL_NAME}))"
    selector: "mail"
    srv_conn: simple_ad
    baseDN: "${var.simple_ad_base_dn}"
  - id: 3
    name: ldap_name
    type: ldap
    value: displayName
    scope: subtree
    filter: "(&(objectClass=user)(sAMAccountName={AZN_CRED_PRINCIPAL_NAME}))"
    selector: "displayName"
    srv_conn: simple_ad
    baseDN: "${var.simple_ad_base_dn}"

rules:
  access_policy:
    - name: allow_all
      content: |
        context.setDecision(Decision.allow());
  mapping:
    - name: pretoken
      rule_type: javascript
      content: |
        // IVIA 25.10 ROPC bug workaround: identity not propagated from ropc rule.
        // Read username from ROPC body params in context attributes.
        var ctx = JSON.parse(mappingrule_context);
        var username = "";
        if (ctx.stsuujson && ctx.stsuujson.contextAttributes) {
          for (var i = 0; i < ctx.stsuujson.contextAttributes.length; i++) {
            var attr = ctx.stsuujson.contextAttributes[i];
            if (attr.name === "username" && attr.values && attr.values.length > 0) {
              username = attr.values[0];
              break;
            }
          }
        }
        if (username && (!stsuu.principalName || stsuu.principalName === "")) {
          stsuu.setPrincipalName(username);
          stsuu.addAttribute(new Attribute("sub", "urn:ibm:jwt:claim", username));
          stsuu.addAttribute(new Attribute("AZN_CRED_PRINCIPAL_NAME", "urn:ibm:names:ITFIM:5.1:accessmanager", username));
          idtokenData.sub = username;
          idtokenData.preferred_username = username;
          tokenData.sub = username;
        }
    - name: posttoken
      rule_type: javascript
      content: |
        // No post-processing needed for workshop
    - name: ropc
      rule_type: javascript
      content: |
        var username = stsuu.principalName;
        stsuu.setPrincipalName(username);
        userData.uid = username;
        userData.sub = username;
        userData.AZN_CRED_PRINCIPAL_NAME = username;
        userData.preferred_username = username;
        idtokenData.sub = username;
        tokenData.sub = username;
    - name: notifyuser
      rule_type: javascript
      content: |
        // InternalAuthenticator: OIDC Provider delegates consent to WRP.
        // WRP serves the login page + /isvaop/oauth2/ciba_user_authorize/{id} consent page.
        // No HTTP call needed — WRP handles everything via junction.
        ciba.setAuthenticator(new InternalAuthenticator());

clients:
  - client_id: workshop_agent
    client_secret: "${random_password.client_secret.result}"
    client_name: "Workshop Agent Client (UC1)"
    enabled: true
    grant_types:
      - client_credentials
    token_endpoint_auth_method: client_secret_basic
    id_token_signed_response_alg: RS256
  - client_id: agent-uc2
    client_secret: "${random_password.client_secret.result}"
    client_name: "Banking App (UC2 — ROPC Login)"
    enabled: true
    grant_types:
      - authorization_code
      - refresh_token
      - password
    response_types:
      - code
    # client_secret_post: ROPC requires client authentication; secret is sent
    # in the POST body. PKCE fields removed — ROPC does not use PKCE.
    # authorization_code + refresh_token grants are retained for the PKCE
    # production upgrade path (add WebSEAL/external IdP to re-enable).
    token_endpoint_auth_method: client_secret_post
    redirect_uris:
      - "${var.uc2_redirect_uri}"
    scopes:
      - openid
      - profile
      - email
  - client_id: agent-uc3
    client_secret: "${random_password.client_secret.result}"
    client_name: "UC3 Refund Agent (CIBA)"
    enabled: true
    grant_types:
      - urn:openid:params:grant-type:ciba
      - urn:ietf:params:oauth:grant-type:token-exchange
    token_endpoint_auth_method: client_secret_post
    backchannel_token_delivery_mode: poll
    authorization_details_types:
      - refund_approval
    scopes:
      - openid
      - profile

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
                DMAP_KEY          VARCHAR(512) NOT NULL PRIMARY KEY,
                DMAP_VALUE        TEXT,
                DMAP_DATATYPE     VARCHAR(64),
                DMAP_EXPIRY       BIGINT
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
              ON DMAP_ENTRIES (DMAP_EXPIRY);

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
      "app.kubernetes.io/version"    = "25.10"
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
          "app.kubernetes.io/version" = "25.10"
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
          image = "icr.io/ivia/ivia-oidc-provider:25.10"

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
    kubernetes_secret.isvaop_ldap,
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
# IVIA Full Stack — Config + WRP + Runtime
#
# The standalone ivia-oidc-provider cannot complete CIBA consent because it has
# no authentication engine. The full IVIA stack adds:
#   ivia-config   — Config container (LMI on port 9443, snapshot publishing)
#   ivia-autoconf — K8s Job that automates Config container setup via REST API
#   ivia-runtime  — AAC Runtime (authentication engine, CIBA auth)
#   ivia-wrp      — Web Reverse Proxy (user-facing entry point, junction routing)
#
# Deployment order (enforced via depends_on):
#   1. Config container starts + PVC + secrets
#   2. autoconf Job configures Config container (activation, WRP junction, ACL)
#   3. Runtime + WRP pull published snapshot from Config container
#
# Reference: IBM-Security/verify-access-container-deployment
#            icr.io/ivia/ivia-config:11.0.2.0 (ivia-minikube.yaml reference)
################################################################################

################################################################################
# IVIA Stack Secrets
################################################################################

# Config container admin password — env ADMIN_PWD on the Config container.
# Also injected into the autoconf job as ISVA_MGMT_PWD.
resource "kubernetes_secret" "ivia_admin" {
  metadata {
    name      = "ivia-admin"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-config"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    password = random_password.ivia_admin_pwd.result
  }
}

# cfgsvc password — CONFIG_SERVICE_USER_PWD on all worker containers.
# Stored in K8s Secret and referenced via secret_key_ref (not plaintext env).
# Threat T-06-08-03: stored in K8s Secret, not plaintext.
resource "kubernetes_secret" "ivia_configreader" {
  metadata {
    name      = "ivia-configreader"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-config"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    password = random_password.configreader_pwd.result
  }
}

################################################################################
# Config Container PVC
# 50Mi ReadWriteOnce — persists Config container state across pod restarts.
# storageClassName gp2 matches the EKS cluster's default StorageClass.
################################################################################

resource "kubernetes_persistent_volume_claim" "ivia_config" {
  wait_until_bound = false

  metadata {
    name      = "ivia-config-pvc"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-config"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "50Mi"
      }
    }

    storage_class_name = "gp2"
  }
}

################################################################################
# Config Container Deployment
# Port 9443 — LMI (Local Management Interface). ClusterIP only (no Ingress).
# Admin password from K8s Secret (Threat T-06-08-01 mitigation).
# Readiness probe on HTTPS /core/login — must pass before autoconf Job runs.
################################################################################

resource "kubernetes_deployment" "ivia_config" {
  metadata {
    name      = "ivia-config"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-config"
      "app.kubernetes.io/version"    = "11.0.2.0"
      "app.kubernetes.io/managed-by" = "terraform"
      "workshop/component"           = "ivia"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-config"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "ivia-config"
          "app.kubernetes.io/version" = "11.0.2.0"
          "workshop/component"        = "ivia"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.isvaop.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.icr_pull.metadata[0].name
        }

        container {
          name  = "ivia-config"
          image = "icr.io/ivia/ivia-config:11.0.2.0"

          port {
            container_port = 9443
            name           = "lmi"
            protocol       = "TCP"
          }

          env {
            name  = "CONTAINER_TIMEZONE"
            value = "UTC"
          }

          env {
            name = "ADMIN_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_admin.metadata[0].name
                key  = "password"
              }
            }
          }

          volume_mount {
            name       = "shared"
            mount_path = "/var/shared"
          }

          volume_mount {
            name       = "logs"
            mount_path = "/var/application.logs"
          }

          readiness_probe {
            http_get {
              path   = "/core/login"
              port   = 9443
              scheme = "HTTPS"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 6
          }

          liveness_probe {
            exec {
              command = ["/sbin/health_check.sh", "livenessProbe"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 6
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
        }

        volume {
          name = "shared"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ivia_config.metadata[0].name
          }
        }

        volume {
          name = "logs"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret.icr_pull,
    kubernetes_secret.ivia_admin,
    kubernetes_secret.ivia_configreader,
    kubernetes_persistent_volume_claim.ivia_config,
  ]
}

################################################################################
# Config Container Service — ClusterIP
# Name "iviaconfig" — used by worker containers as CONFIG_SERVICE_URL hostname.
# Admin LMI REST API also consumed by the autoconf Job on port 9443.
# Threat T-06-08-01: ClusterIP only; no Ingress; admin password in K8s Secret.
################################################################################

resource "kubernetes_service" "ivia_config" {
  metadata {
    name      = "iviaconfig"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-config"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "ivia-config"
    }

    type = "ClusterIP"

    port {
      name        = "lmi"
      port        = 9443
      target_port = 9443
      protocol    = "TCP"
    }
  }
}

################################################################################
# Autoconf ConfigMap
# Contains the ibmvia_autoconf YAML config for activation, cluster setup, and
# WRP instance creation. Shell script handles junction + ACL + snapshot publish
# via ISVA REST API (more reliable than ibmvia_autoconf junction YAML for
# complex junction types).
#
# IMPORTANT: ibmvia_autoconf is experimental for junction configuration.
# Fallback: replace the pip/python command with a pure REST API shell script
# that runs the same steps via curl -k against the LMI API directly.
# See https://lachlan-ibm.github.io/ibmvia_autoconf/ for YAML reference.
################################################################################

resource "kubernetes_config_map" "ivia_autoconf_config" {
  metadata {
    name      = "ivia-autoconf-config"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-autoconf"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    # ibmvia_autoconf YAML — handles activation, cluster config, and WRP instance.
    # Junction and ACL configuration is done via the shell script (more reliable).
    "config.yaml" = <<-EOT
      activation:
        webseal: !environment IVIA_BASE_CODE
        access_control: !environment IVIA_AAC_CODE
        federation: !environment IVIA_FED_CODE
      cluster:
        configuration_database:
          embedded: true
        runtime_database:
          host: !environment PGHOST
          port: !environment PGPORT
          type: postgresql
          user: !environment PGUSER
          password: !environment PGPASSWORD
          ssl: false
          db_name: !environment PGDATABASE
      webseal:
        reverse_proxy:
          - inst_name: default
            host: iviawrp
            admin_id: sec_master
            admin_pwd: !environment ISVA_MGMT_PWD
            domain: Default
            http_port: 80
            https_port: 443
            ip_address: 0.0.0.0
            listening_port: 7234
            ssl: "no"
    EOT

    # Shell script: waits for Config LMI, creates junction /isvaop -> OIDC Provider,
    # sets anyauth ACL on CIBA consent path, then publishes the config snapshot.
    # Runs AFTER ibmvia_autoconf completes activation + WRP instance creation.
    #
    # REST API reference: https://docs.verify.ibm.com/ibm-security-verify-access/docs/api-lmi
    # NOTE: Dollar signs in shell vars are escaped ($$) because this is inside an
    # HCL heredoc that Terraform interpolates. $${VAR} renders as ${VAR} in the file.
    "post-config.sh" = <<-EOT
      #!/bin/sh
      set -e
      BASE_URL="https://iviaconfig.verify-access.svc.cluster.local:9443"

      echo "[post-config] Waiting for LMI to be ready..."
      until curl -sk -o /dev/null -w "%%{http_code}" -u "admin:$${ADMIN_PWD}" "$${BASE_URL}/core/login" 2>/dev/null | grep -q "200"; do
        echo "[post-config] LMI not ready, retrying in 5s..."
        sleep 5
      done
      echo "[post-config] LMI is ready."

      echo "[post-config] Creating junction /isvaop -> isvaop.verify-access.svc.cluster.local:8436 (ssl)..."
      curl -sk -X POST -u "admin:$${ADMIN_PWD}" \
        -H "Accept: application/json" -H "Content-Type: application/json" \
        "$${BASE_URL}/isam/wga/reverseproxy/default/junctions" \
        -d "{\"junction_point\":\"/isvaop\",\"junction_type\":\"ssl\",\"server_hostname\":\"isvaop.verify-access.svc.cluster.local\",\"server_port\":\"8436\",\"stateful_junction\":\"no\",\"insert_session_cookies\":\"yes\"}" \
        || echo "[post-config] Junction may already exist - continuing"

      echo "[post-config] Setting anyauth ACL on CIBA consent path..."
      curl -sk -X PUT -u "admin:$${ADMIN_PWD}" \
        -H "Accept: application/json" -H "Content-Type: application/json" \
        "$${BASE_URL}/isam/wga/reverseproxy/default/acl/attachments" \
        -d "{\"acl_name\":\"anyauth_for_WebSEAL\",\"object_name\":\"/isvaop/oauth2/ciba_user_authorize\"}" \
        || echo "[post-config] ACL attachment may already exist - continuing"

      echo "[post-config] Publishing configuration snapshot..."
      curl -sk -X POST -u "admin:$${ADMIN_PWD}" \
        -H "Accept: application/json" -H "Content-Type: application/json" \
        "$${BASE_URL}/isam/pending_changes/deploy" -d "{}" \
        || echo "[post-config] Snapshot publish warning - check LMI logs"

      echo "[post-config] Configuration complete."
    EOT
  }
}

################################################################################
# Autoconf Job
# Python K8s Job that installs ibmvia_autoconf and runs it against the Config
# container LMI to perform activation, WRP instance creation, junction setup,
# ACL configuration, and snapshot publishing.
#
# Threat T-06-08-05: Uses existing isvaop SA (minimal RBAC) — no cluster-admin.
# Runs after Config container is ready (depends_on ensures ordering).
#
# Note: ibmvia_autoconf is experimental for junction/ACL config. If the tool
# proves problematic, replace with pure curl REST API calls (post-config.sh
# provides the reference implementation for that fallback path).
################################################################################

resource "kubernetes_job" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-autoconf"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "ivia-autoconf"
        }
      }

      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.isvaop.metadata[0].name

        container {
          name  = "autoconf"
          image = "python:3.12-slim"

          command = ["/bin/sh", "-c"]
          args = [
            "pip install --quiet ibmvia_autoconf && python -m ibmvia_autoconf --config /etc/autoconf/config.yaml && sh /etc/autoconf/post-config.sh"
          ]

          env {
            name  = "IVIA_BASE_CODE"
            value = var.ivia_activation_code
          }

          env {
            name  = "IVIA_AAC_CODE"
            value = var.ivia_activation_code
          }

          env {
            name  = "IVIA_FED_CODE"
            value = var.ivia_activation_code
          }

          env {
            name  = "ISVA_MGMT_BASE_URL"
            value = "https://iviaconfig.verify-access.svc.cluster.local:9443"
          }

          env {
            name  = "ISVA_MGMT_USER"
            value = "admin"
          }

          env {
            name = "ISVA_MGMT_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_admin.metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            name = "ADMIN_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_admin.metadata[0].name
                key  = "password"
              }
            }
          }

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

          volume_mount {
            name       = "autoconf-config"
            mount_path = "/etc/autoconf"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "autoconf-config"
          config_map {
            name         = kubernetes_config_map.ivia_autoconf_config.metadata[0].name
            default_mode = "0755"
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }

  depends_on = [
    kubernetes_deployment.ivia_config,
    kubernetes_service.ivia_config,
  ]
}

################################################################################
# AAC Runtime Deployment
# The Runtime provides the authentication engine that WRP delegates to.
# Workers pull configuration snapshots from Config via CONFIG_SERVICE_URL.
# Depends on autoconf Job — Runtime needs the published snapshot with the
# AAC Runtime database connection configured.
#
# Pitfall 1 (Research): Runtime MUST start after Config container is ready
# and the autoconf Job has published the snapshot.
# Threat T-06-08-02: CONFIG_SERVICE_TLS_CACERT=disabled (workshop self-signed).
################################################################################

resource "kubernetes_deployment" "ivia_runtime" {
  metadata {
    name      = "ivia-runtime"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-runtime"
      "app.kubernetes.io/version"    = "11.0.2.0"
      "app.kubernetes.io/managed-by" = "terraform"
      "workshop/component"           = "ivia"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-runtime"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "ivia-runtime"
          "app.kubernetes.io/version" = "11.0.2.0"
          "workshop/component"        = "ivia"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.isvaop.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.icr_pull.metadata[0].name
        }

        container {
          name  = "ivia-runtime"
          image = "icr.io/ivia/ivia-runtime:11.0.2.0"

          port {
            container_port = 9443
            name           = "runtime"
            protocol       = "TCP"
          }

          env {
            name  = "CONFIG_SERVICE_URL"
            value = "https://iviaconfig.verify-access.svc.cluster.local:9443/shared_volume"
          }

          env {
            name  = "CONFIG_SERVICE_USER_NAME"
            value = "cfgsvc"
          }

          env {
            name = "CONFIG_SERVICE_USER_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_configreader.metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            name  = "CONFIG_SERVICE_TLS_CACERT"
            value = "disabled"
          }

          env {
            name  = "CONTAINER_TIMEZONE"
            value = "UTC"
          }

          volume_mount {
            name       = "shared"
            mount_path = "/var/shared"
          }

          volume_mount {
            name       = "logs"
            mount_path = "/var/application.logs"
          }

          readiness_probe {
            http_get {
              path   = "/sps/static/ibm-logo.png"
              port   = 9443
              scheme = "HTTPS"
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            failure_threshold     = 6
          }

          liveness_probe {
            exec {
              command = ["/sbin/health_check.sh", "livenessProbe"]
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            failure_threshold     = 6
          }

          startup_probe {
            exec {
              command = ["/sbin/health_check.sh"]
            }
            period_seconds    = 10
            failure_threshold = 30
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
        }

        volume {
          name = "shared"
          empty_dir {}
        }

        volume {
          name = "logs"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_job.ivia_autoconf,
  ]
}

################################################################################
# Runtime Service — ClusterIP
# Name "iviaruntime" — used by WRP for AAC engine delegation.
################################################################################

resource "kubernetes_service" "ivia_runtime" {
  metadata {
    name      = "iviaruntime"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-runtime"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "ivia-runtime"
    }

    type = "ClusterIP"

    port {
      name        = "runtime"
      port        = 9443
      target_port = 9443
      protocol    = "TCP"
    }
  }
}

################################################################################
# WRP Deployment
# Web Reverse Proxy — the public-facing entry point for browser flows.
# Handles user authentication and forwards authenticated sessions to OIDC
# Provider via junction /isvaop. Routes CIBA consent through /isvaop/oauth2/
# ciba_user_authorize. Requires published Config snapshot from autoconf Job.
#
# Resources: requests 500m/1Gi, limits 2/2Gi — WRP handles all browser traffic.
# Pitfall 6 (Research): WRP ALB replaces existing OIDC Provider ALB for browser
# flows. Machine-to-machine flows (ROPC, token exchange) continue via ClusterIP.
################################################################################

resource "kubernetes_deployment" "ivia_wrp" {
  metadata {
    name      = "ivia-wrp"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-wrp"
      "app.kubernetes.io/version"    = "11.0.2.0"
      "app.kubernetes.io/managed-by" = "terraform"
      "workshop/component"           = "ivia"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-wrp"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "ivia-wrp"
          "app.kubernetes.io/version" = "11.0.2.0"
          "workshop/component"        = "ivia"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.isvaop.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.icr_pull.metadata[0].name
        }

        container {
          name  = "ivia-wrp"
          image = "icr.io/ivia/ivia-wrp:11.0.2.0"

          port {
            container_port = 9443
            name           = "wrp"
            protocol       = "TCP"
          }

          env {
            name  = "CONFIG_SERVICE_URL"
            value = "https://iviaconfig.verify-access.svc.cluster.local:9443/shared_volume"
          }

          env {
            name  = "CONFIG_SERVICE_USER_NAME"
            value = "cfgsvc"
          }

          env {
            name = "CONFIG_SERVICE_USER_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ivia_configreader.metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            name  = "CONFIG_SERVICE_TLS_CACERT"
            value = "disabled"
          }

          env {
            name  = "INSTANCE"
            value = "default"
          }

          env {
            name  = "CONTAINER_TIMEZONE"
            value = "UTC"
          }

          volume_mount {
            name       = "shared"
            mount_path = "/var/shared"
          }

          volume_mount {
            name       = "logs"
            mount_path = "/var/application.logs"
          }

          readiness_probe {
            exec {
              command = ["/sbin/health_check.sh"]
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            failure_threshold     = 6
          }

          liveness_probe {
            exec {
              command = ["/sbin/health_check.sh", "livenessProbe"]
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            failure_threshold     = 6
          }

          startup_probe {
            exec {
              command = ["/sbin/health_check.sh"]
            }
            period_seconds    = 10
            failure_threshold = 30
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2"
              memory = "2Gi"
            }
          }
        }

        volume {
          name = "shared"
          empty_dir {}
        }

        volume {
          name = "logs"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_job.ivia_autoconf,
  ]
}

################################################################################
# WRP Service — ClusterIP
# Name "iviawrp" — referenced in junction config (autoconf WRP instance host).
################################################################################

resource "kubernetes_service" "ivia_wrp" {
  metadata {
    name      = "iviawrp"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "ivia-wrp"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "ivia-wrp"
    }

    type = "ClusterIP"

    port {
      name        = "wrp"
      port        = 9443
      target_port = 9443
      protocol    = "TCP"
    }
  }
}

################################################################################
# WRP Ingress — ALB (internet-facing)
# Backend: WRP on port 9443 (HTTPS). ALB listens on HTTP:80 for workshop
# simplicity (CIBA consent URL in the browser chat message uses HTTP).
# Pitfall 6 (Research): This ALB becomes the sole browser-facing entry point.
# Old OIDC Provider ALB (kubernetes_ingress_v1.isvaop) will be removed in
# Plan 06-09 when OIDC Provider config.yaml is updated with WRP ALB base_url.
################################################################################

resource "kubernetes_ingress_v1" "ivia_wrp" {
  wait_for_load_balancer = true

  metadata {
    name      = "ivia-wrp"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"               = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"          = "ip"
      "alb.ingress.kubernetes.io/listen-ports"         = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/backend-protocol"     = "HTTPS"
      "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTPS"
      "alb.ingress.kubernetes.io/healthcheck-port"     = "9443"
    }
    labels = {
      "app.kubernetes.io/name"       = "ivia-wrp"
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
              name = kubernetes_service.ivia_wrp.metadata[0].name
              port {
                number = 9443
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service.ivia_wrp]
}

################################################################################
# Zero-Trust NetworkPolicies — verify-access namespace
#
# Pattern mirrors banking-app and uc3-agent modules:
#   1. ivia_default_deny    — deny all ingress + egress for every pod
#   2. ivia_allow_dns       — namespace-wide CoreDNS egress exception
#   3. ivia_config_allow_inbound   — LMI on 9443 from within verify-access
#   4. ivia_wrp_allow_ingress      — ALB + banking-app → WRP on 9443
#   5. ivia_wrp_allow_egress       — WRP → OIDC Provider (8436), Runtime/Config (9443), LDAP (389)
#   6. ivia_runtime_allow_inbound  — WRP → Runtime on 9443
#   7. ivia_runtime_allow_egress   — Runtime → Config (9443), LDAP (389), RDS (5432)
#   8. isvaop_allow_inbound        — WRP junction + cluster namespaces → OIDC Provider on 8436
#   9. isvaop_allow_egress         — OIDC Provider → RDS (5432), LDAP (389)
#
# Threat T-06-13-01 mitigated: empty pod_selector covers ALL pods in namespace.
################################################################################

################################################################################
# 1. NetworkPolicy — ivia-default-deny
#
# Zero-trust baseline. Denies all ingress and egress for every pod in the
# verify-access namespace. All subsequent policies carve out required paths.
################################################################################

resource "kubernetes_network_policy" "ivia_default_deny" {
  metadata {
    name      = "ivia-default-deny"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress", "Egress"]
  }
}

################################################################################
# 2. NetworkPolicy — ivia-allow-dns
#
# Namespace-wide DNS exception — all IVIA pods need CoreDNS for service name
# resolution (iviaconfig, iviaruntime, iviawrp, isvaop, RDS hostname).
################################################################################

resource "kubernetes_network_policy" "ivia_allow_dns" {
  metadata {
    name      = "ivia-allow-dns"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # DNS over UDP
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
    }

    # DNS over TCP (large responses)
    egress {
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}

################################################################################
# 3. NetworkPolicy — ivia-config-allow-inbound
#
# Allows LMI access on port 9443 from within the verify-access namespace.
# Callers: autoconf Job (activation + junction setup), WRP + Runtime (snapshot
# pull). Threat T-06-08-01: Config LMI has no external Ingress; this policy
# enforces that only in-namespace pods may reach it.
################################################################################

resource "kubernetes_network_policy" "ivia_config_allow_inbound" {
  metadata {
    name      = "ivia-config-allow-inbound"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-config"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "verify-access"
          }
        }
      }

      ports {
        port     = "9443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}

################################################################################
# 4. NetworkPolicy — ivia-wrp-allow-ingress
#
# Allows inbound traffic to the WRP pod on port 9443 from:
#   - 0.0.0.0/0: ALB ENI IPs (dynamic) + browser CIBA consent traffic
#   - banking-app namespace: CIBA consent redirect chain
#
# Threat T-06-13-02: ALB open CIDR accepted — production adds WAF + IP allowlist.
################################################################################

resource "kubernetes_network_policy" "ivia_wrp_allow_ingress" {
  metadata {
    name      = "ivia-wrp-allow-ingress"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-wrp"
      }
    }

    policy_types = ["Ingress"]

    # ALB health checks + browser traffic (ENI IPs are dynamic)
    ingress {
      from {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }

      ports {
        port     = "9443"
        protocol = "TCP"
      }
    }

    # banking-app namespace (CIBA consent redirect chain)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "banking-app"
          }
        }
      }

      ports {
        port     = "9443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}

################################################################################
# 5. NetworkPolicy — ivia-wrp-allow-egress
#
# WRP outbound paths:
#   - port 8436 TCP: OIDC Provider junction (/isvaop)
#   - port 9443 TCP: AAC Runtime (authentication delegation) + Config (snapshot)
#   - port 389  TCP: LDAP Simple AD (if WRP performs direct LDAP lookup)
################################################################################

resource "kubernetes_network_policy" "ivia_wrp_allow_egress" {
  metadata {
    name      = "ivia-wrp-allow-egress"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-wrp"
      }
    }

    policy_types = ["Egress"]

    # To OIDC Provider via junction (port 8436)
    egress {
      ports {
        port     = "8436"
        protocol = "TCP"
      }
    }

    # To Runtime (AAC delegation) and Config (snapshot pull) on port 9443
    egress {
      ports {
        port     = "9443"
        protocol = "TCP"
      }
    }

    # To LDAP Simple AD on port 389
    egress {
      ports {
        port     = "389"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}

################################################################################
# 6. NetworkPolicy — ivia-runtime-allow-inbound
#
# Allows WRP to reach the Runtime AAC engine on port 9443.
# Only the ivia-wrp pod may initiate this connection.
################################################################################

resource "kubernetes_network_policy" "ivia_runtime_allow_inbound" {
  metadata {
    name      = "ivia-runtime-allow-inbound"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-runtime"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "ivia-wrp"
          }
        }
      }

      ports {
        port     = "9443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}

################################################################################
# 7. NetworkPolicy — ivia-runtime-allow-egress
#
# Runtime outbound paths:
#   - port 9443 TCP: Config container (snapshot pull)
#   - port 389  TCP: LDAP Simple AD (user authentication)
#   - port 5432 TCP: PostgreSQL RDS (runtime session/token database)
################################################################################

resource "kubernetes_network_policy" "ivia_runtime_allow_egress" {
  metadata {
    name      = "ivia-runtime-allow-egress"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "ivia-runtime"
      }
    }

    policy_types = ["Egress"]

    # To Config container on port 9443 (snapshot pull)
    egress {
      ports {
        port     = "9443"
        protocol = "TCP"
      }
    }

    # To LDAP Simple AD on port 389 (user authentication)
    egress {
      ports {
        port     = "389"
        protocol = "TCP"
      }
    }

    # To PostgreSQL RDS on port 5432 (runtime database)
    egress {
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}

################################################################################
# 8. NetworkPolicy — isvaop-allow-inbound
#
# Allows inbound traffic to the OIDC Provider (isvaop) on port 8436 from:
#   - ivia-wrp pod: WRP junction (/isvaop → OIDC Provider backchannel)
#   - banking-app namespace: ROPC login, CIBA bc-authorize, token polling
#   - vault namespace: OIDC discovery (jwt auth method uses /.well-known/openid-configuration)
################################################################################

resource "kubernetes_network_policy" "isvaop_allow_inbound" {
  metadata {
    name      = "isvaop-allow-inbound"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "isvaop"
      }
    }

    policy_types = ["Ingress"]

    # WRP junction (in-namespace ivia-wrp pod)
    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "ivia-wrp"
          }
        }
      }

      ports {
        port     = "8436"
        protocol = "TCP"
      }
    }

    # banking-app namespace (ROPC login, CIBA bc-authorize, token poll)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "banking-app"
          }
        }
      }

      ports {
        port     = "8436"
        protocol = "TCP"
      }
    }

    # vault namespace (OIDC discovery for jwt auth method)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "vault"
          }
        }
      }

      ports {
        port     = "8436"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}

################################################################################
# 9. NetworkPolicy — isvaop-allow-egress
#
# OIDC Provider outbound paths:
#   - port 5432 TCP: PostgreSQL RDS (token cache, session storage)
#   - port 389  TCP: LDAP Simple AD (attribute sources for JWT claims)
################################################################################

resource "kubernetes_network_policy" "isvaop_allow_egress" {
  metadata {
    name      = "isvaop-allow-egress"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "isvaop"
      }
    }

    policy_types = ["Egress"]

    # To PostgreSQL RDS on port 5432 (token/session storage)
    egress {
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }

    # To LDAP Simple AD on port 389 (attribute sources)
    egress {
      ports {
        port     = "389"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.ivia_default_deny]
}
