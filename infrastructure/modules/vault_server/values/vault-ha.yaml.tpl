# Vault Helm HA values template
# Rendered by Terraform templatefile() — variables: kms_key_id, region
# Chart: hashicorp/vault 0.32.0 (server image: hashicorp/vault-enterprise 2.0.3-ent, Phase 9)
# Image repository + tag are pinned literals (not templatefile vars) — the
# workshop deploys a single fixed Enterprise build, not an attendee choice.

global:
  enabled: true

ui:
  enabled: true
  serviceType: ClusterIP

injector:
  enabled: true

server:
  image:
    repository: "hashicorp/vault-enterprise"
    tag: "2.0.3-ent"

  # Enterprise binary hard-fails init without an autoloaded license. The
  # license secret (Opaque, key "license") is provisioned by
  # kubernetes_secret.vault_ent_license in main.tf and populated at deploy
  # time from a per-attendee license file (never a committed literal).
  enterpriseLicense:
    secretName: "vault-ent-license"
    secretKey: "license"

  # Structured JSON logs for fluent-bit pickup.
  # Audit events go to stdout via the "file" audit device pointed at /dev/stdout.
  extraArgs: "-log-format=json"

  # Persistent storage for Raft data (10 Gi per node).
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: gp2

  # Audit device writes to PVC are disabled — stdout audit is used instead.
  auditStorage:
    enabled: false

  # Vault SA is created by Terraform (Pod Identity association).
  # Helm MUST NOT create a conflicting SA.
  serviceAccount:
    create: false
    name: "vault"

  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true

        listener "tcp" {
          address       = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_disable   = true
        }

        storage "raft" {
          path = "/vault/data"

          retry_join {
            leader_api_addr = "http://vault-0.vault-internal:8200"
          }

          retry_join {
            leader_api_addr = "http://vault-1.vault-internal:8200"
          }

          retry_join {
            leader_api_addr = "http://vault-2.vault-internal:8200"
          }
        }

        seal "awskms" {
          region     = "${region}"
          kms_key_id = "${kms_key_id}"
        }

        service_registration "kubernetes" {}
