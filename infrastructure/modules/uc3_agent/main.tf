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
#   - IVIA_CLIENT_SECRET (agent-uc3) and IVIA_ACTOR_CLIENT_SECRET (uc3-actor) are
#     two DISTINCT credentials delivered via kubernetes_secret.uc3_oidc_clients,
#     never the ConfigMap (issue #30).
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
# All NON-SECRET agent configuration is surfaced here so attendees can inspect the
# full environment in Terraform HCL. Credentials are deliberately absent: the two
# OAuth client secrets live in kubernetes_secret.uc3_oidc_clients and the easuser
# SCIM password in kubernetes_secret.uc3_scim_cred.
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
    # IVIA_CLIENT_SECRET / IVIA_ACTOR_CLIENT_SECRET are NOT here — both ride
    # kubernetes_secret.uc3_oidc_clients and reach the container via
    # envFrom.secretRef (issue #30). Nothing in this ConfigMap is secret.
    IVIA_EXTERNAL_URL = var.ivia_external_url
    # The id_token forwarded from banking-ui carries aud = banking-ui's IVIA
    # client_id (e.g. "agent-uc2"), NOT this agent's own IVIA_CLIENT_ID
    # (agent-uc3). verify_id_token() in auth.py validates aud against this.
    IVIA_ID_TOKEN_AUDIENCE = var.ivia_id_token_audience
    IVIA_ACTOR_CLIENT_ID   = "uc3-actor"
    DB_HOST                = var.db_host
    DB_PORT                = tostring(var.db_port)
    DB_NAME                = var.db_name
    BEDROCK_MODEL_ID       = var.bedrock_model_id
    AWS_REGION             = var.region
    # Least-privilege read role — the agent reads transactions/accounts/refunds
    # via this Vault DB role which carries SELECT-only grants (cannot INSERT).
    VAULT_DB_READONLY_PATH = "database/creds/uc3-readonly"
    # iviaop self-signed CA bundle path — auth.py and agent.py verify all
    # outbound IVIA TLS calls against this file (no verify=False).
    IVIA_CA_BUNDLE = "/etc/ssl/ivia/iviaop.pem"
    # AAC runtime (iviaruntime:9443) — mmfa.py fires the MMFA push and reads the
    # admin SCIM MMFA transaction status here (the CIBA mobile-push approval gate).
    # IVIA_SCIM_USER is easuser (not secret); its password is injected via a Secret
    # (secretKeyRef IVIA_SCIM_PASSWORD), never this ConfigMap. The runtime serves a
    # self-signed cert CN=isam (no SAN) — mmfa.py PINS IVIA_RUNTIME_CA_BUNDLE with
    # check_hostname=False (cert-pinning, never verify=False).
    IVIA_RUNTIME_URL       = var.ivia_runtime_url
    IVIA_SCIM_USER         = var.ivia_scim_user
    IVIA_RUNTIME_CA_BUNDLE = "/etc/ssl/ivia/iviaruntime.pem"
  }
}

################################################################################
# 2a. Secret — ivia-oidc-ca-uc3 (iviaop self-signed CA for IVIA_CA_BUNDLE)
#
# The uc3-agent Python process verifies all outbound IVIA TLS calls (CIBA
# bc-authorize, token poll, token exchange, JWKS/discovery) against this CA
# via IVIA_CA_BUNDLE=/etc/ssl/ivia/iviaop.pem — no verify=False in auth.py or
# agent.py. Named ivia-oidc-ca-uc3 (not ivia-oidc-ca) to avoid collision with
# the banking-ui Secret of the same base name in the banking-app namespace
# (created by the uc2_agent module).
################################################################################

resource "kubernetes_secret" "ivia_oidc_ca" {
  metadata {
    name      = "ivia-oidc-ca-uc3"
    namespace = var.namespace
  }

  data = {
    # iviaop OIDC provider cert (:8436) — outbound CIBA/token/JWKS TLS (agent.py, auth.py).
    "iviaop.pem" = var.ivia_oidc_ca_pem
    # iviaruntime AAC cert (:9443, CN=isam, no SAN) — PINNED by mmfa.py for the MMFA
    # push-fire + admin SCIM read (check_hostname=False, never verify=False).
    "iviaruntime.pem" = var.ivia_runtime_ca_pem
  }
}

################################################################################
# 2a-bis. Secret — uc3-oidc-clients (agent-uc3 + uc3-actor client secrets)
#
# Two DISTINCT credentials for two distinct clients:
#   IVIA_CLIENT_SECRET       — agent-uc3, the CIBA client that asks the human to
#                              approve the refund.
#   IVIA_ACTOR_CLIENT_SECRET — uc3-actor, the only client allowed to perform the
#                              RFC 8693 exchange that mints the delegated token
#                              Vault accepts for database/creds/uc3-refund-writer.
#
# Keeping them separate is the point of issue #30: the exchange is a privileged
# step, and holding agent-uc3's credential must not be enough to perform it.
# Both are Secrets, never ConfigMap keys, so the values do not appear in
# `kubectl get configmap uc3-agent-config -o yaml`.
################################################################################

resource "kubernetes_secret" "uc3_oidc_clients" {
  metadata {
    name      = "uc3-oidc-clients"
    namespace = var.namespace
  }

  data = {
    IVIA_CLIENT_SECRET       = var.ivia_client_secret
    IVIA_ACTOR_CLIENT_SECRET = var.ivia_actor_client_secret
  }
}

################################################################################
# 2b. Secret — uc3-scim-cred (easuser password for the admin SCIM read)
#
# mmfa.read_txn_status() does an HTTP Basic admin SCIM GET against iviaruntime:9443
# to resolve the user's OWN MMFA transaction status (the CIBA mobile-push approval
# gate). The username (easuser) is non-secret and rides the ConfigMap; the password
# is injected here via secretKeyRef IVIA_SCIM_PASSWORD — never the ConfigMap.
################################################################################

resource "kubernetes_secret" "uc3_scim_cred" {
  metadata {
    name      = "uc3-scim-cred"
    namespace = var.namespace
  }

  data = {
    password = var.ivia_scim_password
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
        annotations = {
          # Phase 07.8 D-02: roll uc3-agent whenever IVIA's public issuer flips
          # (e.g. deploy-workshop.sh Step 4 flipping wrp from raw ALB → nip.io
          # FQDN). auth.py:_init_jwks_client lazily caches _OIDC_ISSUER from the
          # discovery doc at first verify; with no restart trigger it kept the
          # boot-time issuer and rejected new id_tokens with issuer_mismatch
          # → HTTP 401 on /chat + refund calls. Mirrors uc2_agent's
          # checksum/config pattern (uc2_agent/main.tf:264).
          "checksum/config" = sha256(jsonencode(kubernetes_config_map.uc3_agent.data))
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.uc3_agent.metadata[0].name
        automount_service_account_token = true

        container {
          name              = "uc3-agent"
          image             = var.uc3_agent_image
          image_pull_policy = var.image_pull_policy

          port {
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.uc3_agent.metadata[0].name
            }
          }

          # agent-uc3 + uc3-actor client secrets — Secret, not ConfigMap (issue #30).
          env_from {
            secret_ref {
              name = kubernetes_secret.uc3_oidc_clients.metadata[0].name
            }
          }

          # easuser SCIM password — Secret, not ConfigMap (paired with IVIA_SCIM_USER).
          env {
            name = "IVIA_SCIM_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.uc3_scim_cred.metadata[0].name
                key  = "password"
              }
            }
          }

          volume_mount {
            name       = "ivia-ca"
            mount_path = "/etc/ssl/ivia"
            read_only  = true
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
    kubernetes_service_account.uc3_agent,
    kubernetes_config_map.uc3_agent,
    kubernetes_secret.ivia_oidc_ca,
    kubernetes_secret.uc3_oidc_clients,
    kubernetes_secret.uc3_scim_cred,
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
# 11. NetworkPolicy — uc3-allow-inbound (ingress on TCP 8080)
#
# Ingress on 8080 from: the banking-ui / uc2-agent pods (the chat that drives the
# refund), AND the IVIA namespace — iviaop runs the CIBA checkstatus rule that PUTs
# /api/ciba/status on this service during the token poll.
#
# NOTE: this cluster runs with the EKS network-policy controller DISABLED, so this
# rule is an inert API object documenting intent — the cross-namespace call works
# regardless. Kept additive + accurate so enabling enforcement later is a flip.
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

      # iviaop (CIBA checkstatus rule) calls /api/ciba/status from the IVIA namespace.
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.ivia_namespace
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
