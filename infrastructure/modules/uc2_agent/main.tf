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
#   23. kubernetes_config_map       "seed_sql"             (seed.sql content for DB seed pod)
#   24. null_resource               "db_seed"              (DB seed via kubectl run + psql)
#
# Security design:
#   - Default-deny-all NetworkPolicy in banking-app namespace (ENFC-03 zero-trust baseline).
#   - Per-pod NetworkPolicies allow only the required egress destinations.
#   - uc2-mcp-server-sa is the Vault k8s auth role subject — MCP server issues
#     Vault JWT auth per user request; agent never touches DB credentials.
#   - DB seed provisioner retrieves master credentials from Secrets Manager at apply
#     time; the pod auto-deletes after completion (--rm).
################################################################################

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
# 5. ConfigMap — banking-ui-config
################################################################################

resource "kubernetes_config_map" "banking_ui_config" {
  metadata {
    name      = "banking-ui-config"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  data = {
    PUBLIC_IVIA_ISSUER   = var.ivia_issuer
    PUBLIC_IVIA_CLIENT_ID = var.ivia_client_id
    PUBLIC_REDIRECT_URI  = "http://localhost:5173/callback"
    PUBLIC_AGENT_URL     = "http://banking-agent-svc:3002"
  }
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
    MCP_URL           = "http://banking-mcp-svc:3001/mcp"
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
    VAULT_ADDR      = var.vault_addr
    VAULT_JWT_ROLE  = var.vault_jwt_role
    VAULT_DB_ROLE   = var.vault_db_role
    RDS_ADDRESS     = var.rds_address
    RDS_PORT        = tostring(var.rds_port)
    RDS_DB_NAME     = var.rds_db_name
  }
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
      }

      spec {
        service_account_name            = kubernetes_service_account.uc2_ui_sa.metadata[0].name
        automount_service_account_token = true

        container {
          name  = "banking-ui"
          image = var.ui_image

          port {
            container_port = 5173
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.banking_ui_config.metadata[0].name
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
      }
    }
  }

  depends_on = [
    kubernetes_service_account.uc2_ui_sa,
    kubernetes_config_map.banking_ui_config,
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
          name  = "banking-agent"
          image = var.agent_image

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
          name  = "banking-mcp-server"
          image = var.mcp_image

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
#   - banking-agent-svc:3002  (agent chat API; label match)
#   - IVIA:443                (OIDC discovery + token endpoints; CIDR via default route)
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

    # To IVIA OIDC endpoints (443) — IVIA runs in verify namespace or external
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
# 22. ALB Ingress — banking-ui (internet-facing, HTTP-only)
#
# Routes all HTTP traffic from the internet to banking-ui-svc:80.
# Target-type=ip ensures ALB sends traffic directly to pod IPs (not NodePort).
# HTTPS is omitted in this workshop — the UI uses plain HTTP to simplify the
# PKCE redirect URI configuration for attendees.
################################################################################

resource "kubernetes_ingress_v1" "banking_ui" {
  metadata {
    name      = "banking-ui-ingress"
    namespace = kubernetes_namespace.banking_app.metadata[0].name

    annotations = {
      "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"  = "ip"
      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([{ HTTP = 80 }])
      "kubernetes.io/ingress.class"            = "alb"
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
    kubernetes_deployment.banking_ui,
  ]
}

################################################################################
# 23. ConfigMap — seed-sql
#
# Loads seed.sql content into a ConfigMap so the DB seed pod can mount it
# as a volume file. The ConfigMap lives in banking-app namespace alongside
# the application workloads.
################################################################################

resource "kubernetes_config_map" "seed_sql" {
  metadata {
    name      = "seed-sql"
    namespace = kubernetes_namespace.banking_app.metadata[0].name
  }

  data = {
    "seed.sql" = file("${path.module}/../../applications/banking-app/db/seed.sql")
  }
}

################################################################################
# 24. null_resource — db_seed
#
# Runs the banking schema + RLS seed SQL once (or when seed.sql changes).
#
# Mechanism:
#   - Retrieves master credentials from Secrets Manager at apply time.
#   - Spins up a disposable postgres:16-alpine pod with --rm (auto-deletes).
#   - Mounts seed-sql ConfigMap volume to /seed/seed.sql.
#   - Runs psql against the RDS endpoint.
#
# Idempotency:
#   - triggers = { seed_hash } prevents re-run when seed.sql is unchanged.
#   - seed.sql itself is idempotent (IF NOT EXISTS + ON CONFLICT DO NOTHING).
################################################################################

resource "null_resource" "db_seed" {
  triggers = {
    seed_hash = filemd5("${path.module}/../../applications/banking-app/db/seed.sql")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SECRET=$(aws secretsmanager get-secret-value \
        --secret-id "${var.rds_master_user_secret_arn}" \
        --query SecretString --output text)
      MASTER_USER=$(echo "$SECRET" | jq -r '.username')
      MASTER_PASSWORD=$(echo "$SECRET" | jq -r '.password')

      kubectl run db-seed-uc2 \
        --namespace=banking-app \
        --image=postgres:16-alpine \
        --restart=Never \
        --rm \
        -i \
        --timeout=60s \
        --overrides="{
          \"spec\": {
            \"containers\": [{
              \"name\": \"db-seed-uc2\",
              \"image\": \"postgres:16-alpine\",
              \"command\": [
                \"psql\",
                \"-h\", \"${var.rds_address}\",
                \"-p\", \"${var.rds_port}\",
                \"-U\", \"$MASTER_USER\",
                \"-d\", \"${var.rds_db_name}\",
                \"-f\", \"/seed/seed.sql\"
              ],
              \"volumeMounts\": [{\"name\": \"seed\", \"mountPath\": \"/seed\"}],
              \"env\": [{\"name\": \"PGPASSWORD\", \"value\": \"$MASTER_PASSWORD\"}]
            }],
            \"volumes\": [{\"name\": \"seed\", \"configMap\": {\"name\": \"seed-sql\"}}],
            \"restartPolicy\": \"Never\"
          }
        }"
    EOT
  }

  depends_on = [
    kubernetes_config_map.seed_sql,
    kubernetes_deployment.banking_ui,
    kubernetes_deployment.banking_agent,
    kubernetes_deployment.banking_mcp_server,
  ]
}
