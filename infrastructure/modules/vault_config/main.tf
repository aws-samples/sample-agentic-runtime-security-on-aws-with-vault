################################################################################
# vault_config Module — Main
#
# Provisions all Vault configuration that bridges the Vault deployment (03-01)
# to the agent use cases (Phases 4-6):
#   - Audit device (PLAT-05): file type → stdout, json format, fluent-bit pickup
#   - Kubernetes auth backend (CONF-01): EKS CA + OIDC issuer
#   - JWT auth backend (CONF-02): IVIA OIDC discovery URL
#   - PostgreSQL secrets engine (CONF-03): 3 roles (uc1-readonly,
#     uc2-personal-readonly, uc3-refund-writer)
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
  type         = "jwt"
  path         = "jwt"
  jwks_url     = var.ivia_jwks_url
  jwks_ca_pem  = var.ivia_oidc_ca_pem
  bound_issuer = var.ivia_issuer
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
  allowed_roles     = ["uc1-readonly", "uc2-personal-readonly", "uc3-refund-writer"]
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

# uc2-personal-readonly: SELECT only on banking schema, 15-min TTL
# Layer 2 enforcement (ENFC-02): R/O only — INSERT/UPDATE/DELETE denied at Postgres level
# search_path set to banking,public so the role lands in the banking schema by default.
resource "vault_database_secret_backend_role" "uc2_personal_readonly" {
  backend     = vault_mount.database.path
  name        = "uc2-personal-readonly"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 900  # 15 minutes
  max_ttl     = 1800 # 30 minutes
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "ALTER ROLE \"{{name}}\" SET search_path TO banking,public;",
    "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
    "GRANT SELECT ON ALL TABLES IN SCHEMA banking TO \"{{name}}\";",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA banking GRANT SELECT ON TABLES TO \"{{name}}\";"
  ]
  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE USAGE ON SCHEMA banking FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}

# uc3-refund-writer: tightly-scoped banking schema grants, 5-min TTL (financial write)
# Pitfall 6 fix: original creation_statements targeted public schema — UC3 data lives in
# banking schema. Fixed to:
#   - USAGE on banking schema
#   - SELECT on banking.transactions (read source records, no write)
#   - SELECT + INSERT + UPDATE on banking.refunds (write approved refunds, no DELETE)
#   - search_path set to banking,public so the role lands in the right schema by default
resource "vault_database_secret_backend_role" "uc3_refund_writer" {
  backend     = vault_mount.database.path
  name        = "uc3-refund-writer"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 300 # 5 minutes
  max_ttl     = 600 # 10 minutes
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' BYPASSRLS;",
    "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
    "GRANT SELECT ON banking.accounts TO \"{{name}}\";",
    "GRANT SELECT ON banking.transactions TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON banking.refunds TO \"{{name}}\";",
    "ALTER ROLE \"{{name}}\" SET search_path TO banking,public;"
  ]
  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE USAGE ON SCHEMA banking FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}

################################################################################
# AWS secrets engine — CONF-04
# assumed_role credential_type; Bedrock reader role bound to InvokeModel + Retrieve
################################################################################

resource "vault_aws_secret_backend" "this" {
  path   = "aws"
  region = var.region
}

resource "vault_aws_secret_backend_role" "bedrock_reader" {
  backend         = vault_aws_secret_backend.this.path
  name            = "bedrock-reader"
  credential_type = "assumed_role"

  role_arns = [var.bedrock_role_arn]

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Retrieve"
        ]
        Resource = "*"
      }
    ]
  })
}

# UC3 logs-writer aws/sts role (OBJ-2, CONTEXT Delta-6) — mirrors bedrock_reader.
# Vended short-lived to the agent so it can write the ivia_decisions ANCHOR
# record to CloudWatch without any standing AWS identity. The inline session
# policy_document is scoped (belt-and-suspenders alongside the assumable role's
# own policy) to ONLY logs:PutLogEvents + logs:CreateLogStream on the single
# /workshop/ivia-decision log group — never the wildcard form (threat T-071-02, HIGH).
# The account id is parsed from the assumable role ARN (arn:aws:iam::<acct>:role/..)
# so the module needs no aws_caller_identity data source; region is var.region.
locals {
  uc3_logs_account_id = split(":", var.uc3_logs_role_arn)[4]
  uc3_logs_group_arn  = "arn:aws:logs:${var.region}:${local.uc3_logs_account_id}:log-group:/workshop/ivia-decision:*"
}

resource "vault_aws_secret_backend_role" "uc3_logs_writer" {
  backend         = vault_aws_secret_backend.this.path
  name            = "uc3-logs-writer"
  credential_type = "assumed_role"

  role_arns = [var.uc3_logs_role_arn]

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogStream"
        ]
        Resource = local.uc3_logs_group_arn
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
    # Allows: kubernetes auth login, database creds, Vault-vended Bedrock STS creds, Vault identity lookup
    path "database/creds/uc1-readonly" {
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

resource "vault_policy" "uc2_personal" {
  name = "uc2-personal"

  policy = <<-EOT
    # UC2: Personal-data agent policy (ENFC-02)
    # Allows: kubernetes + jwt auth login, database creds (R/O), AWS (Bedrock) STS creds
    # database/creds/uc2-personal-readonly only — no write DB roles accessible
    path "database/creds/uc2-personal-readonly" {
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
    # Allows: kubernetes + jwt auth login, database write creds, AWS (Bedrock) STS creds,
    # AWS (CloudWatch logs) STS creds for the ivia_decisions anchor emission (OBJ-5)
    path "database/creds/uc3-refund-writer" {
      capabilities = ["read"]
    }
    path "aws/sts/bedrock-reader" {
      capabilities = ["read", "update"]
    }
    path "aws/sts/uc3-logs-writer" {
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
  bound_service_account_names      = ["uc1-retriever-sa"]
  bound_service_account_namespaces = ["uc1"]
  token_policies                   = [vault_policy.uc1_readonly.name]
  token_ttl                        = 3600 # 1 hour
  token_max_ttl                    = 7200 # 2 hours
}

resource "vault_kubernetes_auth_backend_role" "uc2" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "uc2"
  bound_service_account_names      = ["uc2-mcp-server-sa"]
  bound_service_account_namespaces = ["banking-app"]
  token_policies                   = [vault_policy.uc2_personal.name]
  token_ttl                        = 3600
  token_max_ttl                    = 7200
}

resource "vault_policy" "uc2_agent" {
  name = "uc2-agent"

  policy = <<-EOT
    # UC2 Agent: Bedrock STS only — no database credentials
    # Agent's DB access flows through MCP server (user JWT → Vault jwt auth → per-user DB creds)
    path "aws/sts/bedrock-reader" {
      capabilities = ["read", "update"]
    }
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "uc2_agent" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "uc2-agent"
  bound_service_account_names      = ["uc2-agent-sa"]
  bound_service_account_namespaces = ["banking-app"]
  token_policies                   = [vault_policy.uc2_agent.name]
  token_ttl                        = 3600
  token_max_ttl                    = 7200
}

resource "vault_kubernetes_auth_backend_role" "uc3" {
  backend                     = vault_auth_backend.kubernetes.path
  role_name                   = "uc3"
  bound_service_account_names = ["uc3-privileged-actor-sa"]
  # Pitfall 5 fix: UC3 agent runs in banking-app namespace (same as UC1/UC2 agents)
  # not a dedicated "uc3" namespace — bound namespace must match actual pod namespace.
  bound_service_account_namespaces = ["banking-app"]
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

  # Require IVIA-issued tokens only (validated via jwks_url)
  bound_claims = {}

  # Map user sub claim into Vault entity metadata for audit correlation (OBJ-5)
  claim_mappings = {
    "sub"   = "user_sub"
    "email" = "user_email"
  }
}

resource "vault_jwt_auth_backend_role" "uc3_jwt" {
  backend        = vault_jwt_auth_backend.ivia.path
  role_name      = "uc3-jwt"
  role_type      = "jwt"
  token_policies = [vault_policy.uc3_refund_writer.name]
  token_ttl      = 3600
  token_max_ttl  = 7200

  # The RFC 8693 token-exchange output JWT's audience is the client that PERFORMED
  # the exchange (uc3-actor), not the subject's client (agent-uc3). Bind to the
  # actor — that is the verified, natural ISVAOP behavior.
  bound_audiences = ["uc3-actor"]

  user_claim = "sub"

  # may_act signals RFC 8693 delegation: the agent must present an exchanged token
  # carrying it before Vault issues DB write creds. ISVAOP emits may_act as a JSON
  # object {"sub":"uc3-actor"} (injected by the isvaop_pretoken mapping rule), so
  # we match the nested member with a JSONPointer key — Vault cannot match a
  # map-valued claim directly. glob "*" accepts any actor sub; tighten to the
  # exact value ("uc3-actor") if a single fixed actor is desired.
  bound_claims_type = "glob"
  bound_claims = {
    "/may_act/sub" = "*"
  }

  # Audit-only metadata extraction (OBJ-4 / OBJ-5 three-plane correlation).
  # claim_mappings writes nested JWT claims into auth.metadata (map<string,string>)
  # at jwt login; it does NOT participate in authorization enforcement (that stays
  # in bound_claims above — threat T-071-03, disposition accept). JSONPointer keys
  # are supported identically to bound_claims
  # [CITED: developer.hashicorp.com/vault/api-docs/auth/jwt#claim_mappings].
  #   /may_act/sub                  -> auth.metadata.may_act_sub  (the RFC 8693 actor sub)
  #   /authorization_details/0/type -> auth.metadata.rar_type     (the RAR grant type)
  claim_mappings = {
    "/may_act/sub"                  = "may_act_sub"
    "/authorization_details/0/type" = "rar_type"
  }
}
