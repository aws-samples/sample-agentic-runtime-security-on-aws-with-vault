################################################################################
# uc3_agent Module — Main
#
# Provisions all Kubernetes resources for the UC3 CIBA-privileged action agent:
#
#   1.  kubernetes_service_account  "uc3_agent"            (uc3-privileged-actor-sa)
#   2.  kubernetes_config_map       "uc3_agent"            (uc3-agent-config)
#   3.  kubernetes_deployment       "uc3_agent"            (port 8080, 1 replica)
#   4.  kubernetes_service          "uc3_agent"            (ClusterIP 8080 → 8080)
#   5.  kubernetes_network_policy   "uc3_default_deny"     (deny all ingress + egress)
#   6.  kubernetes_network_policy   "uc3_allow_dns"        (egress UDP/TCP 53)
#   7.  kubernetes_network_policy   "uc3_allow_vault"      (egress TCP 8200)
#   8.  kubernetes_network_policy   "uc3_allow_rds"        (egress TCP 5432 via CIDR)
#   9.  kubernetes_network_policy   "uc3_allow_ivia"       (egress TCP 443/9443)
#   10. kubernetes_network_policy   "uc3_allow_bedrock"    (egress TCP 443 via VPC endpoint)
#   11. kubernetes_network_policy   "uc3_allow_inbound"    (ingress from banking-agent:8080)
#
# Security design:
#   - uc3-privileged-actor-sa is the Vault k8s auth role subject — the agent presents
#     its SA JWT to Vault and exchanges it for a short-TTL uc3-refund-writer token
#     whose may_act + RAR claims are validated by the Vault JWT policy (OBJ-2 + OBJ-3).
#   - No Ingress / ALB — the UC3 agent is a ClusterIP service reached from
#     the banking-agent (uc2-agent) or via kubectl port-forward for workshop demos.
#   - IVIA_CLIENT_SECRET stored in ConfigMap per Phase 5.2 workshop-simplicity decision.
#     Production deployments should use a Kubernetes Secret with secretKeyRef.
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
# 1. ServiceAccount — uc3-privileged-actor-sa
#
# Vault Kubernetes auth role "uc3" is bound to this SA name in the banking-app
# namespace. The agent mounts the projected SA JWT at the standard path and
# submits it to Vault /auth/kubernetes/login at startup.
################################################################################

resource "kubernetes_service_account" "uc3_agent" {
  metadata {
    name      = "uc3-privileged-actor-sa"
    namespace = var.namespace
    labels = {
      app       = "uc3-agent"
      component = "uc3"
    }
  }
  automount_service_account_token = true
}

################################################################################
# 2. ConfigMap — uc3-agent-config
#
# All agent configuration is surfaced here so attendees can inspect the full
# environment in Terraform HCL without chasing Secrets. The IVIA_CLIENT_SECRET
# inclusion follows the Phase 5.2 workshop-simplicity decision (comment above).
################################################################################

resource "kubernetes_config_map" "uc3_agent" {
  metadata {
    name      = "uc3-agent-config"
    namespace = var.namespace
    labels = {
      app       = "uc3-agent"
      component = "uc3"
    }
  }

  data = {
    VAULT_ADDR     = var.vault_endpoint
    VAULT_ROLE     = var.vault_role
    IVIA_BASE_URL  = var.ivia_base_url
    IVIA_CLIENT_ID = var.ivia_client_id
    # IVIA_CLIENT_SECRET: workshop stores in ConfigMap for simplicity.
    # Production deployments should use a Kubernetes Secret with secretKeyRef.
    IVIA_CLIENT_SECRET = var.ivia_client_secret
    IVIA_EXTERNAL_URL      = var.ivia_external_url
    IVIA_ACTOR_CLIENT_ID   = "uc3-actor"
    DB_HOST            = var.db_host
    DB_PORT            = tostring(var.db_port)
    DB_NAME            = var.db_name
    BEDROCK_MODEL_ID   = var.bedrock_model_id
    AWS_REGION         = var.region
  }
}

################################################################################
# 3. Deployment — uc3-agent (Python FastAPI, port 8080)
#
# Single-replica deployment. The SA JWT automount provides the credential the
# agent needs for Vault k8s auth. envFrom loads all runtime config from the
# ConfigMap defined above.
################################################################################

resource "kubernetes_deployment" "uc3_agent" {
  wait_for_rollout = false

  metadata {
    name      = "uc3-agent"
    namespace = var.namespace
    labels = {
      app       = "uc3-agent"
      component = "uc3"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

    template {
      metadata {
        labels = {
          app       = "uc3-agent"
          component = "uc3"
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.uc3_agent.metadata[0].name
        automount_service_account_token = true

        container {
          name              = "uc3-agent"
          image             = var.uc3_agent_image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.uc3_agent.metadata[0].name
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.uc3_agent,
    kubernetes_config_map.uc3_agent,
  ]
}

################################################################################
# 4. Service — uc3-agent-svc (ClusterIP 8080 → 8080)
#
# Internal-only. No Ingress / ALB — the UC3 agent is invoked by the banking-agent
# (uc2-agent) via in-cluster DNS or reached via kubectl port-forward for demos.
################################################################################

resource "kubernetes_service" "uc3_agent" {
  metadata {
    name      = "uc3-agent-svc"
    namespace = var.namespace
    labels = {
      app       = "uc3-agent"
      component = "uc3"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "uc3-agent"
    }

    port {
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

################################################################################
# 5. NetworkPolicy — uc3-default-deny (zero-trust baseline for uc3-agent pods)
#
# Blocks ALL ingress and egress for uc3-agent pods. Per-pod policies below
# selectively open only required paths (ENFC-03 enforcement).
################################################################################

resource "kubernetes_network_policy" "uc3_default_deny" {
  metadata {
    name      = "uc3-default-deny"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

    policy_types = ["Ingress", "Egress"]
  }
}

################################################################################
# 6. NetworkPolicy — uc3-allow-dns (CoreDNS egress for uc3-agent pods)
#
# UC3 agent needs DNS to resolve Vault, IVIA, and RDS hostnames.
################################################################################

resource "kubernetes_network_policy" "uc3_allow_dns" {
  metadata {
    name      = "uc3-allow-dns"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

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

  depends_on = [kubernetes_network_policy.uc3_default_deny]
}

################################################################################
# 7. NetworkPolicy — uc3-allow-vault (Vault k8s auth + secret vending)
#
# UC3 agent authenticates to Vault at pod start using its SA JWT, then fetches
# a short-TTL uc3-refund-writer database credential for each privileged action.
################################################################################

resource "kubernetes_network_policy" "uc3_allow_vault" {
  metadata {
    name      = "uc3-allow-vault"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

    policy_types = ["Egress"]

    egress {
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.uc3_default_deny]
}

################################################################################
# 8. NetworkPolicy — uc3-allow-rds (PostgreSQL write access via Vault creds)
#
# Scoped to var.rds_cidr (VPC CIDR) so the rule covers the RDS subnet group
# without allowing arbitrary internet egress on 5432.
################################################################################

resource "kubernetes_network_policy" "uc3_allow_rds" {
  metadata {
    name      = "uc3-allow-rds"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

    policy_types = ["Egress"]

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
  }

  depends_on = [kubernetes_network_policy.uc3_default_deny]
}

################################################################################
# 9. NetworkPolicy — uc3-allow-ivia (CIBA polling + token introspection)
#
# UC3 agent polls IVIA CIBA /bc-authorize and /token endpoints (HTTPS:443)
# and may also reach IVIA internal admin port (TCP:9443) for backchannel ops.
################################################################################

resource "kubernetes_network_policy" "uc3_allow_ivia" {
  metadata {
    name      = "uc3-allow-ivia"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

    policy_types = ["Egress"]

    # IVIA external HTTPS (ALB or direct)
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    # IVIA internal admin / backchannel port
    egress {
      ports {
        port     = "9443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.uc3_default_deny]
}

################################################################################
# 10. NetworkPolicy — uc3-allow-bedrock (LLM inference via VPC endpoint)
#
# Bedrock InvokeModel traffic exits through the Bedrock VPC interface endpoint
# on TCP 443. The CIDR is open (0.0.0.0/0) because VPC endpoint IPs are
# dynamic; security is enforced by the VPC endpoint policy + IAM role.
################################################################################

resource "kubernetes_network_policy" "uc3_allow_bedrock" {
  metadata {
    name      = "uc3-allow-bedrock"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }

      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.uc3_default_deny]
}

################################################################################
# 11. NetworkPolicy — uc3-allow-inbound (ingress from banking-agent on TCP 8080)
#
# The UC3 agent is invoked by the banking-agent (uc2-agent label) to perform
# privileged refund operations after CIBA consent is granted.
################################################################################

resource "kubernetes_network_policy" "uc3_allow_inbound" {
  metadata {
    name      = "uc3-allow-inbound"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "uc3-agent"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            app = "uc2-agent"
          }
        }
      }

      from {
        pod_selector {
          match_labels = {
            app = "banking-ui"
          }
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.uc3_default_deny]
}
