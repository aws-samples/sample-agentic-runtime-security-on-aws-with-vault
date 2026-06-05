################################################################################
# uc2_agent Module — Main
#
# Provisions all Kubernetes resources for the UC2 OAuth-personalized banking app:
#
#   1.  kubernetes_namespace        "banking_app"          (banking-app)
#   2.  kubernetes_service_account  "uc2_ui_sa"            (uc2-ui-sa)
#   3.  kubernetes_service_account  "uc2_agent_sa"         (uc2-agent-sa)
#   4.  kubernetes_service_account  "uc2_mcp_server_sa"    (uc2-mcp-server-sa)
#   5.  kubernetes_config_map       "banking_ui_config"    (banking-ui-config)
#   6.  kubernetes_config_map       "banking_agent_config" (banking-agent-config)
#   7.  kubernetes_config_map       "banking_mcp_config"   (banking-mcp-config)
#   8.  kubernetes_deployment       "banking_ui"           (port 5173)
#   9.  kubernetes_deployment       "banking_agent"        (port 3002)
#   10. kubernetes_deployment       "banking_mcp_server"   (port 3001)
#   11. kubernetes_service          "banking_ui_svc"       (ClusterIP 80→5173)
#   12. kubernetes_service          "banking_agent_svc"    (ClusterIP 3002→3002)
#   13. kubernetes_service          "banking_mcp_svc"      (ClusterIP 3001→3001)
#   14. kubernetes_network_policy   "default_deny"         (zero-trust baseline)
#   15. kubernetes_network_policy   "allow_dns"            (53/UDP+TCP namespace-wide)
#   16. kubernetes_network_policy   "banking_ui_ingress"   (ALB health + user traffic)
#   17. kubernetes_network_policy   "banking_ui_egress"    (→ agent:3002, IVIA:443)
#   18. kubernetes_network_policy   "banking_agent_ingress"(← UI:3002)
#   19. kubernetes_network_policy   "banking_agent_egress" (→ MCP:3001, Vault:8200, Bedrock:443)
#   20. kubernetes_network_policy   "banking_mcp_ingress"  (← agent:3001)
#   21. kubernetes_network_policy   "banking_mcp_egress"   (→ Vault:8200, RDS:5432, IVIA:443)
#   22. kubernetes_ingress_v1       "banking_ui"           (ALB, internet-facing, HTTP-only)
#
# Security design:
#   - Default-deny-all NetworkPolicy in banking-app namespace (ENFC-03 zero-trust baseline).
#   - Per-pod NetworkPolicies allow only the required egress destinations.
#   - uc2-mcp-server-sa is the Vault k8s auth role subject — MCP server issues
#     Vault JWT auth per user request; agent never touches DB credentials.
#   - DB seeding runs post-deploy via seed-banking-db.sh (Stacks does not support local-exec).
################################################################################

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

################################################################################
# 1. Namespace
################################################################################

resource "kubernetes_namespace" "banking_app" {
  metadata {
    name = "banking-app"
    labels = {
      app = "banking-app"
    }
  }
}

################################################################################
# 2–4. ServiceAccounts
#
# uc2-ui-sa       — SvelteKit UI; no Vault access (public OAuth client)
# uc2-agent-sa    — Strands agent; uses SA JWT for its own Vault k8s auth
# uc2-mcp-server-sa — MCP server; bound to Vault uc2 k8s auth role; issues
#                     per-user JWT auth to Vault for DB credential vending
################################################################################

resource "kubernetes_service_account" "uc2_ui_sa" {
  metadata {
    name      = "uc2-ui-sa"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-ui"
      component = "uc2"
    }
  }
  automount_service_account_token = true
}

resource "kubernetes_service_account" "uc2_agent_sa" {
  metadata {
    name      = "uc2-agent-sa"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-agent"
      component = "uc2"
    }
  }
  automount_service_account_token = true
}

resource "kubernetes_service_account" "uc2_mcp_server_sa" {
  metadata {
    name      = "uc2-mcp-server-sa"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-mcp-server"
      component = "uc2"
    }
  }
  automount_service_account_token = true
}

################################################################################
# Locals — compute URLs from Ingress ALB hostnames
################################################################################

locals {
  # The banking-ui's own ALB hostname (LBC-assigned, post-reconcile). Used both
  # as a module output and as the browser-facing https origin/redirect_uri.
  # Referencing it here makes banking_ui_config implicitly depend on the Ingress,
  # so the ConfigMap is rendered only after the ALB hostname exists — no
  # post-hoc patch needed. The Ingress depends only on banking_ui_svc, so there
  # is no cycle.
  banking_ui_alb_hostname = kubernetes_ingress_v1.banking_ui.status[0].load_balancer[0].ingress[0].hostname
  # Browser-facing HTTPS URLs. The app's own origin/redirect_uri uses its own ALB
  # host; the OIDC issuer uses the ivia-wrp (login) ALB host passed in from root.
  # IVIAOP rejects http redirect_uris for non-localhost, so both are https; the
  # ALB serves a self-signed cert (attendee accepts the browser prompt once).
  banking_ui_external_url = "https://${local.banking_ui_alb_hostname}"
  ivia_external_url       = "${var.ivia_public_issuer}/isvaop"

  banking_ui_config_data = {
    # Server-side vars (SvelteKit $env/dynamic/private — login + callback routes)
    IVIA_ISSUER    = local.ivia_external_url
    IVIA_CLIENT_ID = var.ivia_client_id
    # IVIA_CLIENT_SECRET: workshop stores in ConfigMap for simplicity.
    # Production deployments should use a Kubernetes Secret with secretKeyRef.
    IVIA_CLIENT_SECRET     = var.ivia_client_secret
    IVIA_BASE_URL          = "https://${var.ivia_service_endpoint}:8436"
    UC3_IVIA_CLIENT_ID     = "agent-uc3"
    UC3_IVIA_CLIENT_SECRET = var.ivia_client_secret
    REDIRECT_URI           = "${local.banking_ui_external_url}/callback"
    # Client-side vars (SvelteKit PUBLIC_ prefix — auth.ts PKCE upgrade path)
    PUBLIC_IVIA_ISSUER    = local.ivia_external_url
    PUBLIC_IVIA_CLIENT_ID = var.ivia_client_id
    PUBLIC_REDIRECT_URI   = "${local.banking_ui_external_url}/callback"
    # Server-side proxy (SvelteKit $env/dynamic/private) — /api/chat + /api/uc3-chat + /api/ask routes
    AGENT_URL     = "http://banking-agent-svc:3002"
    UC3_AGENT_URL = "http://uc3-agent-svc:8080"
    # /api/ask (public Use Case 1 page) proxies to the uc1-agent in the uc1
    # namespace. Cross-namespace, so the fully-qualified service DNS is required.
    UC1_AGENT_URL = "http://uc1-agent-svc.uc1.svc.cluster.local"
    # SvelteKit CSRF protection: ORIGIN must match the browser's Origin header
    ORIGIN = local.banking_ui_external_url
    # The /callback handler POSTs to IVIA_BASE_URL (in-cluster DNS, HTTPS)
    # for the authorization code → token exchange. iviaop presents a
    # self-signed certificate (httpserverkey/httpservercert) that is not
    # trusted by Node's default CA bundle. TLS verification is enabled;
    # the iviaop CA cert is trusted via NODE_EXTRA_CA_CERTS mounted from
    # the ivia-oidc-ca Secret at /etc/ssl/ivia/iviaop.pem.
  }
}

################################################################################
# 5. ConfigMap — banking-ui-config
################################################################################

resource "kubernetes_config_map" "banking_ui_config" {
  metadata {
    name      = "banking-ui-config"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  data = local.banking_ui_config_data
}

################################################################################
# 6. ConfigMap — banking-agent-config
################################################################################

resource "kubernetes_config_map" "banking_agent_config" {
  metadata {
    name      = "banking-agent-config"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  data = {
    VAULT_ADDR        = var.vault_addr
    VAULT_ROLE        = var.vault_k8s_role
    MCP_URL           = "http://banking-mcp-svc:3001"
    BEDROCK_MODEL_ID  = var.bedrock_model_id
    AWS_REGION        = var.region
    KB_REGION         = var.kb_region
    KNOWLEDGE_BASE_ID = var.knowledge_base_id
  }
}

################################################################################
# 7. ConfigMap — banking-mcp-config
################################################################################

resource "kubernetes_config_map" "banking_mcp_config" {
  metadata {
    name      = "banking-mcp-config"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  data = {
    VAULT_ADDR     = var.vault_addr
    VAULT_JWT_ROLE = var.vault_jwt_role
    VAULT_DB_ROLE  = var.vault_db_role
    RDS_ADDRESS    = var.rds_address
    RDS_PORT       = tostring(var.rds_port)
    RDS_DB_NAME    = var.rds_db_name
  }
}

################################################################################
# 8a. Secret — ivia-oidc-ca (iviaop self-signed CA for NODE_EXTRA_CA_CERTS)
#
# The banking-ui Node.js process trusts the iviaop self-signed certificate via
# NODE_EXTRA_CA_CERTS=/etc/ssl/ivia/iviaop.pem, which is backed by this Secret.
# TLS is verified; no insecure runtime overrides are needed.
################################################################################

resource "kubernetes_secret" "ivia_oidc_ca" {
  metadata {
    name      = "ivia-oidc-ca"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  data = {
    "iviaop.pem" = var.ivia_oidc_ca_pem
  }

  depends_on = [kubernetes_namespace.banking_app]
}

################################################################################
# 8. Deployment — banking-ui (SvelteKit OAuth PKCE)
################################################################################

resource "kubernetes_deployment" "banking_ui" {
  wait_for_rollout = false

  metadata {
    name      = "banking-ui"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-ui"
      component = "uc2"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "banking-ui"
      }
    }

    template {
      metadata {
        labels = {
          app       = "banking-ui"
          component = "uc2"
        }
        annotations = {
          "checksum/config" = sha256(jsonencode(local.banking_ui_config_data))
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.uc2_ui_sa.metadata[0].name
        automount_service_account_token = true

        container {
          name              = "banking-ui"
          image             = var.ui_image
          image_pull_policy = "Always"

          port {
            container_port = 5173
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.banking_ui_config.metadata[0].name
            }
          }

          env {
            name  = "NODE_EXTRA_CA_CERTS"
            value = "/etc/ssl/ivia/iviaop.pem"
          }

          volume_mount {
            name       = "ivia-ca"
            mount_path = "/etc/ssl/ivia"
            read_only  = true
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
              path = "/"
              port = 5173
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 5173
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "ivia-ca"
          secret {
            secret_name = kubernetes_secret.ivia_oidc_ca.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.uc2_ui_sa,
    kubernetes_config_map.banking_ui_config,
    kubernetes_secret.ivia_oidc_ca,
  ]
}

################################################################################
# 9. Deployment — banking-agent (Python Strands agent)
################################################################################

resource "kubernetes_deployment" "banking_agent" {
  wait_for_rollout = false

  metadata {
    name      = "banking-agent"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-agent"
      component = "uc2"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "banking-agent"
      }
    }

    template {
      metadata {
        labels = {
          app       = "banking-agent"
          component = "uc2"
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.uc2_agent_sa.metadata[0].name
        automount_service_account_token = true

        container {
          name              = "banking-agent"
          image             = var.agent_image
          image_pull_policy = "Always"

          port {
            container_port = 3002
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.banking_agent_config.metadata[0].name
            }
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
              path = "/health"
              port = 3002
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 3002
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.uc2_agent_sa,
    kubernetes_config_map.banking_agent_config,
  ]
}

################################################################################
# 10. Deployment — banking-mcp-server (Node.js MCP server)
################################################################################

resource "kubernetes_deployment" "banking_mcp_server" {
  wait_for_rollout = false

  metadata {
    name      = "banking-mcp-server"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-mcp-server"
      component = "uc2"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "banking-mcp-server"
      }
    }

    template {
      metadata {
        labels = {
          app       = "banking-mcp-server"
          component = "uc2"
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.uc2_mcp_server_sa.metadata[0].name
        automount_service_account_token = true

        container {
          name              = "banking-mcp-server"
          image             = var.mcp_image
          image_pull_policy = "Always"

          port {
            container_port = 3001
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.banking_mcp_config.metadata[0].name
            }
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
              path = "/health"
              port = 3001
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 3001
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.uc2_mcp_server_sa,
    kubernetes_config_map.banking_mcp_config,
  ]
}

################################################################################
# 11. Service — banking-ui-svc (ClusterIP 80 → 5173)
################################################################################

resource "kubernetes_service" "banking_ui_svc" {
  metadata {
    name      = "banking-ui-svc"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-ui"
      component = "uc2"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "banking-ui"
    }

    port {
      port        = 80
      target_port = 5173
      protocol    = "TCP"
    }
  }
}

################################################################################
# 12. Service — banking-agent-svc (ClusterIP 3002 → 3002)
################################################################################

resource "kubernetes_service" "banking_agent_svc" {
  metadata {
    name      = "banking-agent-svc"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-agent"
      component = "uc2"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "banking-agent"
    }

    port {
      port        = 3002
      target_port = 3002
      protocol    = "TCP"
    }
  }
}

################################################################################
# 13. Service — banking-mcp-svc (ClusterIP 3001 → 3001)
################################################################################

resource "kubernetes_service" "banking_mcp_svc" {
  metadata {
    name      = "banking-mcp-svc"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
    labels = {
      app       = "banking-mcp-server"
      component = "uc2"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "banking-mcp-server"
    }

    port {
      port        = 3001
      target_port = 3001
      protocol    = "TCP"
    }
  }
}

################################################################################
# 14. NetworkPolicy — default-deny-all (ENFC-03 zero-trust baseline)
#
# Blocks ALL ingress and egress for every pod in the banking-app namespace.
# Per-pod policies below selectively open only required paths.
################################################################################

resource "kubernetes_network_policy" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress", "Egress"]
  }
}

################################################################################
# 15. NetworkPolicy — allow-dns (CoreDNS egress for all pods)
#
# Namespace-wide DNS exception — all pods need name resolution.
# Separate from per-pod egress policies so CoreDNS is never accidentally blocked.
################################################################################

resource "kubernetes_network_policy" "allow_dns" {
  metadata {
    name      = "allow-dns"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
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

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 16. NetworkPolicy — banking-ui-ingress
#
# Allows ingress from 0.0.0.0/0 on port 5173 — ALB health checks and user
# browser traffic arrive from the ALB ENI IPs (dynamic; open CIDR required).
################################################################################

resource "kubernetes_network_policy" "banking_ui_ingress" {
  metadata {
    name      = "banking-ui-ingress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "banking-ui"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }

      ports {
        port     = "5173"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 17. NetworkPolicy — banking-ui-egress
#
# UI may reach:
#   - banking-agent-svc:3002       (agent chat API; label match)
#   - uc3-agent-svc:8080           (UC3 CIBA privileged agent; label match)
#   - IVIA:80                      (WRP ALB HTTP — CIBA consent redirect)
#   - IVIA:443                     (OIDC discovery + JWKS via internal service)
#   - IVIA:9443                    (WRP ClusterIP + ISVAOP backchannel on actual container port)
#   - verify-access namespace:9443 (CIBA bc-authorize, token poll, consent redirect)
################################################################################

resource "kubernetes_network_policy" "banking_ui_egress" {
  metadata {
    name      = "banking-ui-egress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "banking-ui"
      }
    }

    policy_types = ["Egress"]

    # To banking-agent-svc on port 3002 (label selector — in-cluster)
    egress {
      to {
        pod_selector {
          match_labels = {
            app = "banking-agent"
          }
        }
      }

      ports {
        port     = "3002"
        protocol = "TCP"
      }
    }

    # To uc3-agent-svc on port 8080 (UC3 CIBA privileged refund agent)
    egress {
      to {
        pod_selector {
          match_labels = {
            app = "uc3-agent"
          }
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }

    # To IVIA ALB (HTTP:80) — WRP CIBA consent redirect + token endpoints
    egress {
      ports {
        port     = "80"
        protocol = "TCP"
      }
    }

    # To IVIA OIDC internal service (HTTPS:443) — OIDC discovery + JWKS
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    # To verify-access namespace on port 9443 — WRP + ISVAOP actual container port.
    # Required for CIBA bc-authorize, token polling, and consent redirect chain.
    egress {
      to {
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

    # To verify-access namespace on port 8436 — ISVAOP backchannel (ROPC, token exchange)
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "verify-access"
          }
        }
      }

      ports {
        port     = "8436"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 17b. NetworkPolicy — banking-ui-from-verify-access-ingress
#
# Allows the verify-access namespace (WRP) to initiate connections back to
# banking-ui on port 5173 during the CIBA consent redirect flow.
# WRP redirects the authenticated browser session back to the banking app
# after the user approves the CIBA consent.
################################################################################

resource "kubernetes_network_policy" "banking_ui_from_verify_access_ingress" {
  metadata {
    name      = "banking-ui-from-verify-access-ingress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "banking-ui"
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
        port     = "5173"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 18. NetworkPolicy — banking-agent-ingress
#
# Allows ingress from banking-ui pods on port 3002.
################################################################################

resource "kubernetes_network_policy" "banking_agent_ingress" {
  metadata {
    name      = "banking-agent-ingress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "banking-agent"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            app = "banking-ui"
          }
        }
      }

      ports {
        port     = "3002"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 19. NetworkPolicy — banking-agent-egress
#
# Agent may reach:
#   - banking-mcp-svc:3001  (MCP tool server; label selector)
#   - Vault:8200             (k8s auth login at startup; port-only match)
#   - Bedrock:443            (InvokeModel via VPC endpoint; port-only match)
################################################################################

resource "kubernetes_network_policy" "banking_agent_egress" {
  metadata {
    name      = "banking-agent-egress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "banking-agent"
      }
    }

    policy_types = ["Egress"]

    # To banking-mcp-svc on port 3001 (label selector — in-cluster)
    egress {
      to {
        pod_selector {
          match_labels = {
            app = "banking-mcp-server"
          }
        }
      }

      ports {
        port     = "3001"
        protocol = "TCP"
      }
    }

    # To Vault cluster-internal API (vault namespace pods)
    egress {
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }

    # To Bedrock VPC endpoint + STS (443)
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 20. NetworkPolicy — banking-mcp-ingress
#
# Allows ingress from banking-agent pods on port 3001.
################################################################################

resource "kubernetes_network_policy" "banking_mcp_ingress" {
  metadata {
    name      = "banking-mcp-ingress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "banking-mcp-server"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            app = "banking-agent"
          }
        }
      }

      ports {
        port     = "3001"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 21. NetworkPolicy — banking-mcp-egress
#
# MCP server may reach:
#   - Vault:8200   (JWT auth per user request + DB cred vending)
#   - RDS:5432     (CIDR — VPC-internal; uses Vault-vended ephemeral creds)
#   - IVIA:443     (token validation fallback; CIDR)
################################################################################

resource "kubernetes_network_policy" "banking_mcp_egress" {
  metadata {
    name      = "banking-mcp-egress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "banking-mcp-server"
      }
    }

    policy_types = ["Egress"]

    # To Vault cluster-internal API
    egress {
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }

    # To RDS PostgreSQL (VPC CIDR block — aws service, not k8s pod)
    egress {
      to {
        ip_block {
          cidr = var.rds_cidr
        }
      }

      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }

    # To IVIA (443) — for token verification
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

################################################################################
# 22. ALB Ingress — banking-ui (internet-facing)
#
# Routes internet traffic to banking-ui-svc:80 over an HTTPS:443 listener
# (self-signed *.<region>.elb.amazonaws.com cert), with HTTP:80 redirected to
# 443. The OAuth redirect_uri (https://<this-alb-host>/callback) requires https
# — IVIAOP rejects http redirect_uris for non-localhost hosts.
################################################################################

resource "kubernetes_ingress_v1" "banking_ui" {
  wait_for_load_balancer = true

  metadata {
    name      = "banking-ui-ingress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name

    annotations = {
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn" = var.tls_certificate_arn
      "kubernetes.io/ingress.class"               = "alb"
      # Phase 07.8 Plan 02 (D-01): join the shared ALB IngressGroup so this
      # Ingress co-tenants ONE ALB with the IVIA WRP Ingress. Plan 03
      # cert-manager Certificate's HTTP-01 solver Ingress lands in the same
      # group with group.order=1 so /.well-known/acme-challenge/* wins before
      # this Ingress's /* catch-all (group.order=10).
      "alb.ingress.kubernetes.io/group.name"  = "workshop-acme"
      "alb.ingress.kubernetes.io/group.order" = "10"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service.banking_ui_svc.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service.banking_ui_svc,
  ]
}

