################################################################################
# uc1_agent Module — Main
#
# Provisions all Kubernetes resources required to deploy the UC1 non-personalized
# read-only Strands agent:
#
#   1. kubernetes_namespace       "uc1"
#   2. kubernetes_service_account "uc1-retriever-sa"   (SA JWT → Vault k8s auth)
#   3. kubernetes_config_map      "uc1-config"          (runtime env)
#   4. kubernetes_deployment      "uc1-agent"           (FastAPI + Strands agent)
#   5. kubernetes_service         "uc1-agent-svc"       (ClusterIP 80→8080)
#   6. kubernetes_network_policy  "uc1-egress"          (ENFC-01 egress gates)
#
# Vault wiring: uc1-retriever-sa is bound to the "uc1" Kubernetes auth role in
# vault_config — the pod mounts its SA JWT at the default projection path and
# the agent calls Vault's /auth/kubernetes/login at startup.
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

resource "kubernetes_namespace" "uc1" {
  metadata {
    name = "uc1"
    labels = {
      app = "uc1-agent"
    }
  }
}

################################################################################
# 2. ServiceAccount
# automount_service_account_token = true injects the SA JWT into the pod via
# the default projected volume at /var/run/secrets/kubernetes.io/serviceaccount/
# — the agent reads this token to authenticate to Vault's k8s auth backend.
################################################################################

resource "kubernetes_service_account" "uc1" {
  metadata {
    name      = "uc1-retriever-sa"
    namespace = kubernetes_namespace.uc1.metadata[0].name
    labels = {
      app = "uc1-agent"
    }
  }

  automount_service_account_token = true
}

################################################################################
# 3. ConfigMap — runtime environment
# All region-sensitive values flow through var.region / var.kb_region.
# No hardcoded region string literals — see var.region and var.kb_region.
################################################################################

resource "kubernetes_config_map" "uc1_config" {
  metadata {
    name      = "uc1-config"
    namespace = kubernetes_namespace.uc1.metadata[0].name
  }

  # NOTE: key names must match what agent/app/agent.py reads via os.getenv:
  # DB_HOST/DB_PORT/DB_NAME (db tool), REGION (model-invocation plane),
  # KB_REGION/KNOWLEDGE_BASE_ID (kb retrieve), BEDROCK_MODEL_ID, VAULT_*.
  # AWS_REGION is also kept so the AWS SDK's default region resolution works.
  data = {
    VAULT_ADDR        = var.vault_addr
    VAULT_ROLE        = var.vault_role
    DB_HOST           = var.rds_address
    DB_PORT           = tostring(var.rds_port)
    DB_NAME           = var.rds_db_name
    KNOWLEDGE_BASE_ID = var.knowledge_base_id
    KB_REGION         = var.kb_region
    AWS_REGION        = var.region
    REGION            = var.region
    BEDROCK_MODEL_ID  = var.bedrock_model_id
  }
}

################################################################################
# 4. Deployment
################################################################################

resource "kubernetes_deployment" "uc1" {
  wait_for_rollout = false

  metadata {
    name      = "uc1-agent"
    namespace = kubernetes_namespace.uc1.metadata[0].name
    labels = {
      app = "uc1-agent"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "uc1-agent"
      }
    }

    template {
      metadata {
        labels = {
          app = "uc1-agent"
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.uc1.metadata[0].name
        automount_service_account_token = true

        container {
          name              = "agent"
          image             = var.agent_image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.uc1_config.metadata[0].name
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
    kubernetes_service_account.uc1,
    kubernetes_config_map.uc1_config,
  ]
}

################################################################################
# 5. Service — ClusterIP 80 → 8080
################################################################################

resource "kubernetes_service" "uc1" {
  metadata {
    name      = "uc1-agent-svc"
    namespace = kubernetes_namespace.uc1.metadata[0].name
    labels = {
      app = "uc1-agent"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "uc1-agent"
    }

    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

################################################################################
# 6. NetworkPolicy — ENFC-01 egress gates
#
# Egress rules (allow list — all other egress is denied by default NetworkPolicy):
#   - 53/UDP  kube-dns   (CoreDNS resolution)
#   - 8200/TCP Vault      (cluster-internal; vault.vault.svc)
#   - 5432/TCP RDS        (Vault-vended ephemeral DB creds)
#   - 443/TCP  Bedrock + STS VPC endpoints + NAT GW for cross-region KB retrieve
#
# No ingress rules here; attendees may add an ingress policy for port 80 via
# the workshop verification step if needed.
################################################################################

resource "kubernetes_network_policy" "uc1_egress" {
  metadata {
    name      = "uc1-egress"
    namespace = kubernetes_namespace.uc1.metadata[0].name
  }

  spec {
    pod_selector {} # applies to all pods in the uc1 namespace

    policy_types = ["Egress"]

    # kube-dns (CoreDNS)
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
    }

    # Vault cluster-internal API
    egress {
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }

    # RDS PostgreSQL
    egress {
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }

    # Bedrock InvokeModel, Bedrock KB retrieve, STS AssumeRole
    # (VPC interface endpoints on 443; cross-region KB traffic exits via NAT GW)
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}
