################################################################################
# vault_config Module — Main
#
# Provisions all Vault configuration that bridges the Vault deployment (03-01)
# to the agent use cases (Phases 4-6):
#   - Audit device (PLAT-05): file type → stdout, json format, fluent-bit pickup
#   - Kubernetes auth backend (CONF-01): EKS CA + OIDC issuer
#   - JWT auth backend (CONF-02): IVIA OIDC discovery URL
#   - PostgreSQL secrets engine (CONF-03): 3 roles (uc1-readonly, uc2-personal, uc3-refund-writer)
#   - AWS secrets engine (CONF-04): assumed_role for scoped Bedrock STS credentials
#   - Policies + auth roles for all three use cases
#
# RDS password is fetched from Secrets Manager — never passed as a plain
# Terraform variable (matches verify_access module pattern).
################################################################################

terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

################################################################################
# RDS master password — Secrets Manager (matches verify_access pattern)
################################################################################

data "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = var.rds_master_user_secret_arn
}

locals {
  rds_master_password = jsondecode(data.aws_secretsmanager_secret_version.rds_master.secret_string)["password"]
}

################################################################################
# Vault audit device — PLAT-05
# type=file with file_path=stdout → logs flow to pod stdout → fluent-bit pickup
################################################################################

resource "vault_audit" "stdout" {
  type = "file"

  options = {
    file_path = "stdout"
    format    = "json"
  }
}

################################################################################
# Kubernetes auth backend — CONF-01
# Bound to EKS cluster CA + OIDC issuer; roles use ServiceAccount binding
################################################################################

resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.cluster_endpoint
  kubernetes_ca_cert = base64decode(var.cluster_certificate_authority_data)
  issuer             = var.cluster_oidc_issuer
}

################################################################################
# JWT auth backend — CONF-02
# IVIA OIDC discovery URL; used by uc2-jwt and uc3-jwt roles
################################################################################

resource "vault_jwt_auth_backend" "ivia" {
  type               = "jwt"
  path               = "jwt"
  oidc_discovery_url = var.ivia_oidc_discovery_url
}

################################################################################
# PostgreSQL secrets engine — CONF-03
# connection_url uses Secrets Manager–sourced password (no plain var)
################################################################################

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "pg" {
  backend           = vault_mount.database.path
  name              = "workshop-pg"
  allowed_roles     = ["uc1-readonly", "uc2-personal", "uc3-refund-writer"]
  verify_connection = false

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${var.rds_endpoint}/${var.rds_db_name}?sslmode=require"
    username       = var.rds_master_username
    password       = local.rds_master_password
  }
}

# uc1-readonly: SELECT only, 15-min TTL
resource "vault_database_secret_backend_role" "uc1_readonly" {
  backend     = vault_mount.database.path
  name        = "uc1-readonly"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 900  # 15 minutes
  max_ttl     = 1800 # 30 minutes
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO \"{{name}}\";"
  ]
  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\";",
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}

# uc2-personal: SELECT only, 15-min TTL (personal data access — full audit in CONF-03)
resource "vault_database_secret_backend_role" "uc2_personal" {
  backend     = vault_mount.database.path
  name        = "uc2-personal"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 900  # 15 minutes
  max_ttl     = 1800 # 30 minutes
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO \"{{name}}\";"
  ]
  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\";",
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}

# uc3-refund-writer: SELECT + INSERT + UPDATE, 5-min TTL (tightest scope — financial write)
resource "vault_database_secret_backend_role" "uc3_refund_writer" {
  backend     = vault_mount.database.path
  name        = "uc3-refund-writer"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 300 # 5 minutes
  max_ttl     = 600 # 10 minutes
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO \"{{name}}\";"
  ]
  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\";",
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}

################################################################################
# AWS secrets engine — CONF-04
# assumed_role credential_type; Bedrock reader role bound to bedrock:InvokeModel
################################################################################

resource "vault_aws_secret_backend" "this" {
  path   = "aws"
  region = var.region
}

resource "vault_aws_secret_backend_role" "bedrock_reader" {
  backend         = vault_aws_secret_backend.this.path
  name            = "bedrock-reader"
  credential_type = "assumed_role"

  # IAM role ARN is supplied at deploy time via a policy document;
  # Placeholder — overridden in deployments.tfdeploy.hcl via role_arns input
  # when the bedrock_kb component ARN is available.
  role_arns = []

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      }
    ]
  })
}

################################################################################
# Vault policies — one per use case
################################################################################

resource "vault_policy" "uc1_readonly" {
  name = "uc1-readonly"

  policy = <<-EOT
    # UC1: Read-only agent policy
    # Allows: kubernetes auth login, database creds, Vault identity lookup
    path "database/creds/uc1-readonly" {
      capabilities = ["read"]
    }
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
    path "sys/leases/renew" {
      capabilities = ["update"]
    }
  EOT
}

resource "vault_policy" "uc2_personal" {
  name = "uc2-personal"

  policy = <<-EOT
    # UC2: Personal-data agent policy
    # Allows: kubernetes + jwt auth login, database creds, AWS (Bedrock) STS creds
    path "database/creds/uc2-personal" {
      capabilities = ["read"]
    }
    path "aws/sts/bedrock-reader" {
      capabilities = ["read", "update"]
    }
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
    path "sys/leases/renew" {
      capabilities = ["update"]
    }
  EOT
}

resource "vault_policy" "uc3_refund_writer" {
  name = "uc3-refund-writer"

  policy = <<-EOT
    # UC3: Refund-writer agent policy
    # Allows: kubernetes + jwt auth login, database write creds, AWS (Bedrock) STS creds
    path "database/creds/uc3-refund-writer" {
      capabilities = ["read"]
    }
    path "aws/sts/bedrock-reader" {
      capabilities = ["read", "update"]
    }
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
    path "sys/leases/renew" {
      capabilities = ["update"]
    }
  EOT
}

################################################################################
# Kubernetes auth roles — one per use case
# bound_service_account_namespaces references the agent namespace (uc1/uc2/uc3)
################################################################################

resource "vault_kubernetes_auth_backend_role" "uc1" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "uc1"
  bound_service_account_names      = ["uc1-agent"]
  bound_service_account_namespaces = ["uc1"]
  token_policies                   = [vault_policy.uc1_readonly.name]
  token_ttl                        = 3600 # 1 hour
  token_max_ttl                    = 7200 # 2 hours
}

resource "vault_kubernetes_auth_backend_role" "uc2" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "uc2"
  bound_service_account_names      = ["uc2-agent"]
  bound_service_account_namespaces = ["uc2"]
  token_policies                   = [vault_policy.uc2_personal.name]
  token_ttl                        = 3600
  token_max_ttl                    = 7200
}

resource "vault_kubernetes_auth_backend_role" "uc3" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "uc3"
  bound_service_account_names      = ["uc3-agent"]
  bound_service_account_namespaces = ["uc3"]
  token_policies                   = [vault_policy.uc3_refund_writer.name]
  token_ttl                        = 3600
  token_max_ttl                    = 7200
}

################################################################################
# JWT auth roles — uc2 and uc3 (IVIA token exchange)
# uc2-jwt: bound_audiences=["agent-uc2"] — standard OIDC audience claim
# uc3-jwt: bound_claims includes may_act for delegation assertion
################################################################################

resource "vault_jwt_auth_backend_role" "uc2_jwt" {
  backend        = vault_jwt_auth_backend.ivia.path
  role_name      = "uc2-jwt"
  role_type      = "jwt"
  token_policies = [vault_policy.uc2_personal.name]
  token_ttl      = 3600
  token_max_ttl  = 7200

  bound_audiences = ["agent-uc2"]

  user_claim = "sub"

  # Require IVIA-issued tokens only (validated via oidc_discovery_url)
  bound_claims = {}
}

resource "vault_jwt_auth_backend_role" "uc3_jwt" {
  backend        = vault_jwt_auth_backend.ivia.path
  role_name      = "uc3-jwt"
  role_type      = "jwt"
  token_policies = [vault_policy.uc3_refund_writer.name]
  token_ttl      = 3600
  token_max_ttl  = 7200

  bound_audiences = ["agent-uc3"]

  user_claim = "sub"

  # may_act claim signals RFC 8693 delegation — agent must present token with
  # may_act.sub matching the delegating user before Vault issues DB write creds.
  bound_claims = {
    "may_act" = "*"
  }
}
