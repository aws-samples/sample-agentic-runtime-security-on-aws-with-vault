################################################################################
# vault_config Module — Main
#
# Provisions all Vault configuration that bridges the Vault deployment (03-01)
# to the agent use cases (Phases 4-6):
#   - Audit device (PLAT-05): file type → stdout, json format, fluent-bit pickup
#   - Kubernetes auth backend (CONF-01): EKS CA + OIDC issuer
#   - OAuth resource server (CONF-02): IVIA-native OAuth JWT authorizes Vault
#     directly via X-Vault-Token (jwt auth backend retired — decision (e))
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
      source = "hashicorp/vault"
      # 5.10.1 is the first release exposing vault_oauth_resource_server_config_profile
      # + vault_agent_registration (09-DISCOVERY PROVIDER_MIN=hashicorp/vault>=5.10.1).
      # Pin the exact patch floor (~> 5.10 would admit 5.10.0, which lacks the resource).
      version = ">= 5.10.1, < 6.0.0"
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
# OAuth resource server — CONF-02 (Vault-native cutover, replaces the jwt backend)
#
# Locked decision (e): the IVIA jwt auth backend + uc2-jwt/uc3-jwt roles are
# RETIRED (full native cutover, no fallback). IVIA's OAuth JWT now authorizes a
# Vault request DIRECTLY via the X-Vault-Token header against this resource-server
# profile — no jwt_login round-trip, no synthetic Vault token.
#
# The profile maps 1:1 onto the retired backend's connection facts
# (issuer/JWKS/CA/audiences/RS256). user_claim="sub" extracts the SUBJECT (human
# `sub` for UC3, app `sub` for UC2 — 09-DISCOVERY USER_CLAIM_UNIFORM=yes → ONE
# profile serves both OAuth UCs). The AGENT is resolved by Vault's NATIVE OBO
# handling of the RFC 8693 `act.sub` claim (Plan 04 makes IVIA emit it; Plan 05's
# actor alias binds it), NOT via user_claim — do NOT set user_claim to
# /may_act/sub or act.sub. The wrong-actor deny that the retired role's
# bound_claims (/may_act/sub=uc3-actor) performed is re-homed natively:
# 09-DISCOVERY DELEGATION_ENFORCED=yes proves a wrong actor → 403, so no extra
# profile-level control is required.
#
# optional_authorization_details is deliberately NOT set here: 09-DISCOVERY
# OPT_AUTH_DETAILS_LEVEL=registration → Plan 05 sets it per vault_agent_registration
# (UC3=false RAR-mandatory; UC1/UC2=true RAR-optional). Never an unconditional
# profile-wide false.
################################################################################

# Activation gate — the oauth-resource-server feature must be enabled before the
# profile (and Plan 05's agent registrations) reconcile.
resource "vault_activation_flags" "oauth_resource_server" {
  feature = "oauth-resource-server"
}

resource "vault_oauth_resource_server_config_profile" "ivia" {
  # 1:1 connection map from the retired IVIA jwt auth backend:
  #   bound_issuer → issuer_id (immutable)
  #   jwks_url     → use_jwks + jwks_uri
  #   jwks_ca_pem  → jwks_ca_pem
  #   bound_audiences (uc2-jwt=agent-uc2, uc3-jwt=uc3-actor) → audiences
  # profile_name is REQUIRED by the provider (5.10.1 schema) — names this profile.
  profile_name         = "ivia"
  issuer_id            = var.ivia_issuer
  use_jwks             = true
  jwks_uri             = var.ivia_jwks_url
  jwks_ca_pem          = var.ivia_oidc_ca_pem
  audiences            = ["uc3-actor", "agent-uc2"]
  supported_algorithms = ["RS256"]
  user_claim           = "sub"

  depends_on = [vault_activation_flags.oauth_resource_server]
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
  allowed_roles     = ["uc1-readonly", "uc2-personal-readonly", "uc3-refund-writer", "uc3-readonly"]
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
    # Mirror of the creation_statement's ALTER DEFAULT PRIVILEGES GRANT — undoes the
    # pg_default_acl row that the GRANT left behind. Without this matching REVOKE,
    # DROP ROLE fails because the default-ACL entry is a dependent object. We use the
    # symmetric REVOKE rather than DROP OWNED BY because RDS master (vault_root) is
    # rds_superuser, not a true PG superuser, and is not a member of the ephemeral role
    # — so DROP OWNED BY aborts with SQLSTATE 42501 ("permission denied to drop
    # objects: Only roles with privileges of role X may drop objects owned by it").
    "ALTER DEFAULT PRIVILEGES IN SCHEMA banking REVOKE SELECT ON TABLES FROM \"{{name}}\";",
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
# 07.7 hardening: the row-level-security bypass attribute was removed so this writer is
# now bound by RLS policies like every other role. Defense-in-depth: the RLS WITH CHECK
# policy added in Plan 03 enforces tenant isolation at the INSERT/UPDATE level.
resource "vault_database_secret_backend_role" "uc3_refund_writer" {
  backend     = vault_mount.database.path
  name        = "uc3-refund-writer"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 300 # 5 minutes
  max_ttl     = 600 # 10 minutes
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
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
    # uc3-refund-writer's creation_statements do NOT include ALTER DEFAULT PRIVILEGES,
    # so there is no pg_default_acl dependent row to clean up here — the three REVOKEs
    # above are sufficient before DROP ROLE. See uc2_personal_readonly for the case
    # where a creation_statements ALTER DEFAULT PRIVILEGES requires a symmetric REVOKE
    # in revocation_statements.
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}

# uc3-readonly: SELECT-only on banking schema, 15-min TTL
# Layer 2 enforcement (ENFC-02): read-path tenant isolation — no INSERT/UPDATE/DELETE.
# No row-level-security bypass flag; RLS policies apply to every query this role executes.
# search_path set to banking,public so the role lands in the banking schema by default.
# Explicit GRANT on banking.refunds makes it clear this role can read (but not write) refunds.
resource "vault_database_secret_backend_role" "uc3_readonly" {
  backend     = vault_mount.database.path
  name        = "uc3-readonly"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 900  # 15 minutes
  max_ttl     = 1800 # 30 minutes
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "ALTER ROLE \"{{name}}\" SET search_path TO banking,public;",
    "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
    "GRANT SELECT ON ALL TABLES IN SCHEMA banking TO \"{{name}}\";",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA banking GRANT SELECT ON TABLES TO \"{{name}}\";",
    "GRANT SELECT ON banking.refunds TO \"{{name}}\";"
  ]
  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE USAGE ON SCHEMA banking FROM \"{{name}}\";",
    # Mirror of the creation_statement's ALTER DEFAULT PRIVILEGES GRANT — undoes the
    # pg_default_acl row that the GRANT left behind. Without this matching REVOKE,
    # DROP ROLE fails because the default-ACL entry is a dependent object. We use the
    # symmetric REVOKE rather than DROP OWNED BY because RDS master (vault_root) is
    # rds_superuser, not a true PG superuser, and is not a member of the ephemeral role
    # — so DROP OWNED BY aborts with SQLSTATE 42501 ("permission denied to drop
    # objects: Only roles with privileges of role X may drop objects owned by it").
    "ALTER DEFAULT PRIVILEGES IN SCHEMA banking REVOKE SELECT ON TABLES FROM \"{{name}}\";",
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
    # Allows: kubernetes auth + OAuth resource server (X-Vault-Token), database creds (R/O), AWS (Bedrock) STS creds
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
    # Allows: kubernetes auth + OAuth resource server (X-Vault-Token), database write creds, read-only creds,
    # AWS (Bedrock) STS creds, AWS (CloudWatch logs) STS creds for the
    # ivia_decisions anchor emission (OBJ-5)
    path "database/creds/uc3-refund-writer" {
      capabilities = ["read"]
    }
    path "database/creds/uc3-readonly" {
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

  # Plan 05 (Task 3): make the k8s entity-alias name DETERMINISTIC so the UC1
  # registry-identity alias can be declared in Terraform. Default source
  # "serviceaccount_uid" yields a k8s-runtime UID (unknowable at plan time);
  # "serviceaccount_name" yields "<namespace>/<sa>" = "uc1/uc1-retriever-sa",
  # which vault_identity_entity_alias.uc1_agent binds to the uc1-agent entity.
  # This does NOT change UC1 enforcement — token_policies=[uc1-readonly] is
  # assigned by this role at login independent of the entity alias; the alias
  # only links the login to the uc1-agent Agent-Registry identity.
  alias_name_source = "serviceaccount_name"
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
# JWT auth roles — RETIRED (locked decision (e), full native cutover)
#
# The uc2-jwt + uc3-jwt roles were removed along with the IVIA jwt auth backend
# (both formerly on the retired 'jwt' mount). Their two jobs are re-homed natively:
#   - actor/delegation (/may_act/sub=uc3-actor) → IVIA now emits act.sub (Plan 04)
#     + Plan 05's actor alias (external_id=<act.sub value>) on the agent entity;
#     09-DISCOVERY DELEGATION_ENFORCED=yes proves a wrong actor → 403.
#   - RAR type (/authorization_details/0/type) → per-request vault:path_access RAR
#     (Plan 04 emits it; Plan 05's registration makes it mandatory for UC3).
# No jwt backend is retained as "defense-in-depth" — post-cutover the native
# X-Vault-Token path never traverses auth/jwt, so a retained backend defends zero
# live requests (dead code). The kubernetes auth backend + its uc1/uc2/uc2_agent/
# uc3 roles are UNTOUCHED (UC1 is pure workload; UC2/UC3 human+agent entities are
# added by Plan 05).
################################################################################

################################################################################
# Phase 9, Plan 05 — Native Agent-Identity model (Agent Registry + OBO)
#
# The CORRECTED per-UC identity model (09-DISCOVERY, authoritative):
#   - UC1 = Kubernetes auth. Registry identity only (entity + registration +
#     k8s-mount alias). Ceiling INERT (k8s tokens carry no act.sub, so the
#     agent's own ceiling never self-applies — 09-DISCOVERY
#     CEILING_SELF_APPLIES_SUBJECT_ONLY=no). Enforcement floor is the EXISTING
#     vault_policy.uc1_readonly bound to the uc1 k8s role above — NOT anything
#     added here.
#   - UC2 / UC3 = On-Behalf-Of (OBO). Effective permission =
#     human baseline (∩) agent ceiling (∩) per-request RAR — three layers.
#     `sub`=human resolves the human entity's baseline; `act.sub`=agent resolves
#     the agent entity, contributing its registration ceiling_policies.
#
# Policy CONTENTS below are the 09-DISCOVERY STARTING probe envelopes
# (09-DISCOVERY lines 203-207). They are TUNED against the live workshop dev env
# in the apply->verify loop (locked decision (d); Plan 08 authoritative) — every
# path/capability traces to that envelope, none is invented.
#
# LAYER 1 — UC1 inert ceiling (forward-compat envelope for the registration only)
################################################################################

# UC1 registry ceiling — INERT. Declared solely so the uc1-agent registration has
# a ceiling_policies envelope; it does NOT restrict UC1 at runtime (no act.sub →
# ceiling never self-applies). UC1 enforcement stays vault_policy.uc1_readonly.
# Starting envelope: 09-DISCOVERY line 203 (uc1 registry ceiling).
resource "vault_policy" "uc1_ceiling" {
  name = "uc1-ceiling"

  policy = <<-EOT
    # UC1 registry ceiling (INERT — k8s auth carries no act.sub; never self-applies).
    # Forward-compat max envelope only; the enforcement floor is uc1-readonly.
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

################################################################################
# LAYER 2 — UC2/UC3 HUMAN baselines (attached to the human entity; the human MAX)
################################################################################

# UC2 human baseline — the shared envelope for the closed human set {oscar, jaime}
# (each human's MAX for UC2 personal-data access). Attached to each UC2 human
# entity. Starting envelope: 09-DISCOVERY line 204 (uc2 human baseline, from the
# uc2-personal policy set).
resource "vault_policy" "uc2_human_baseline" {
  name = "uc2-human-baseline"

  policy = <<-EOT
    # UC2 human baseline (sub in {oscar, jaime}) — personal-data read envelope.
    path "database/creds/uc2-personal-readonly" {
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

# UC3 human baseline — jaime's refund-approver envelope (his MAX for UC3). jaime's
# entity carries BOTH this and uc2-human-baseline (his max across both UCs); the
# per-UC agent ceiling intersects it down per request. Starting envelope:
# 09-DISCOVERY line 206 (uc3 human baseline, from the uc3-refund-writer policy set).
resource "vault_policy" "uc3_human_baseline" {
  name = "uc3-human-baseline"

  policy = <<-EOT
    # UC3 human baseline (sub = jaime) — refund-approver envelope.
    path "database/creds/uc3-refund-writer" {
      capabilities = ["read"]
    }
    path "database/creds/uc3-readonly" {
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

################################################################################
# LAYER 3 — UC2/UC3 AGENT ceilings (attached to the registration; restrict-only)
#
# The ceiling is the agent's MAX envelope. In OBO it enforces as an intersection
# with the human baseline (09-DISCOVERY CEILING_ENFORCED_IN_OBO=yes). It never
# GRANTS beyond the human baseline (the human baseline is a floor — a path in the
# ceiling but not the baseline is still denied, 09-DISCOVERY ceiling transcript).
################################################################################

# UC2 agent ceiling (act.sub = agent-uc2). Starting envelope: 09-DISCOVERY line 205.
resource "vault_policy" "uc2_agent_ceiling" {
  name = "uc2-agent-ceiling"

  policy = <<-EOT
    # UC2 agent ceiling (act.sub = agent-uc2) — restrict-only max envelope.
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

# UC3 agent ceiling (act.sub = uc3-actor). Starting envelope: 09-DISCOVERY line 207.
resource "vault_policy" "uc3_agent_ceiling" {
  name = "uc3-agent-ceiling"

  policy = <<-EOT
    # UC3 agent ceiling (act.sub = uc3-actor) — restrict-only max envelope.
    path "database/creds/uc3-refund-writer" {
      capabilities = ["read"]
    }
    path "database/creds/uc3-readonly" {
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
# Identity entities + Agent Registry registrations (Task 2)
#
# FIVE entities: uc1-agent, {oscar, jaime} (shared humans), agent-uc2, uc3-actor.
# THREE registrations: uc1-agent, agent-uc2, uc3-actor (humans are SUBJECTS, not
# registered agents). owner = the operating SERVICE principal (a stable
# service/workload label), NEVER an end-user human — owner is single-valued
# accountability metadata and is NOT load-bearing for OBO resolution
# (09-PATTERNS: resolution is proven via the subject + actor aliases). A shared
# OBO agent (agent-uc2 serves BOTH oscar and jaime) therefore cannot be owned by
# a persona.
################################################################################

locals {
  # Closed OBO human set. jaime overlaps UC2+UC3 → toset() dedupes to ONE entity
  # (aliases are keyed by mount_accessor+external_id; jaime presents the same sub
  # through the same oauth mount in both UCs, so exactly one entity + one alias).
  obo_human_subs = toset(concat(var.uc2_human_subs, [var.uc3_human_sub]))

  # Per-human baseline policy attachment. BOTH personas are refund-capable: the
  # retired uc3-jwt role gated the refund grant on the AGENT delegation
  # (may_act.sub=uc3-actor), NOT the human sub, so every human the UC3 agent acts
  # for gets the refund baseline. Native OBO makes the human baseline a floor, so
  # both carry uc3-human-baseline; per-user RLS still isolates each persona's rows.
  obo_human_policies = {
    for h in local.obo_human_subs : h => compact([
      contains(var.uc2_human_subs, h) ? vault_policy.uc2_human_baseline.name : "",
      vault_policy.uc3_human_baseline.name,
    ])
  }
}

# Every identity write below is ordered AFTER the oauth-resource-server activation
# flag. The gate declared at the top of this file names the agent registrations, but
# the edge only ever reached the config profile — so Terraform was free to schedule
# identity writes concurrently with the activation. An entity create whose request is
# in flight when the feature activates comes back without `id`, and the provider reads
# that field unguarded (resource_identity_entity.go:146), panicking the plugin process
# and failing the whole apply. Observed 2026-08-10: of five entities dispatched in one
# wave, the three issued after the flag landed created in 0s; the two issued before it
# panicked. The registrations and aliases inherit this ordering transitively through
# entity_id / canonical_id, so the edge belongs on the entities.
#
# --- UC1: Kubernetes registry identity (entity + registration; alias in Task 3) ---
resource "vault_identity_entity" "uc1_agent" {
  name = "uc1-agent"
  # No entity policies: UC1's enforcement floor is vault_policy.uc1_readonly bound
  # to the uc1 k8s role. This entity exists purely as the Agent Registry identity;
  # its ceiling is inert (k8s tokens carry no act.sub).

  depends_on = [vault_activation_flags.oauth_resource_server]
}

resource "vault_agent_registration" "uc1_agent" {
  entity_id                 = vault_identity_entity.uc1_agent.id
  display_name              = "uc1-agent" # required, unique, IMMUTABLE
  ceiling_policies          = [vault_policy.uc1_ceiling.name]
  no_default_ceiling_policy = true                    # keep the (inert) ceiling pure
  owner                     = "uc1-retriever-service" # operating SERVICE principal, not a human
  # optional_authorization_details left computed: RAR-optionality is moot for k8s
  # (UC1 presents no OAuth token to Vault).
}

# --- UC2/UC3: shared HUMAN subject entities {oscar, jaime} (NOT registered) ---
resource "vault_identity_entity" "human" {
  for_each = local.obo_human_subs
  name     = each.value
  policies = local.obo_human_policies[each.key]

  depends_on = [vault_activation_flags.oauth_resource_server]
}

# --- UC2 agent (agent-uc2): entity + registration ---
resource "vault_identity_entity" "agent_uc2" {
  name = var.uc2_agent_identity # "agent-uc2"
  # No baseline policies: in OBO the agent contributes its ceiling via the
  # registration below, not via entity policies.

  depends_on = [vault_activation_flags.oauth_resource_server]
}

resource "vault_agent_registration" "agent_uc2" {
  entity_id                      = vault_identity_entity.agent_uc2.id
  display_name                   = var.uc2_agent_identity
  ceiling_policies               = [vault_policy.uc2_agent_ceiling.name]
  no_default_ceiling_policy      = true
  owner                          = "banking-app-service" # operating SERVICE principal (serves oscar AND jaime — never a persona)
  optional_authorization_details = true                  # UC2 RAR OPTIONAL (locked decision (b), cutover committed)
}

# --- UC3 agent (uc3-actor): entity + registration ---
resource "vault_identity_entity" "uc3_actor" {
  name = var.uc3_agent_identity # "uc3-actor" — the ACTOR, not the human sub

  depends_on = [vault_activation_flags.oauth_resource_server]
}

resource "vault_agent_registration" "uc3_actor" {
  entity_id                      = vault_identity_entity.uc3_actor.id
  display_name                   = var.uc3_agent_identity
  ceiling_policies               = [vault_policy.uc3_agent_ceiling.name]
  no_default_ceiling_policy      = true
  owner                          = "uc3-refund-agent-service" # operating SERVICE principal (jaime is the SUBJECT, not the owner)
  optional_authorization_details = false                      # UC3 RAR MANDATORY
}

################################################################################
# Identity entity ALIASES (Task 3)
#
# UC1 = ONE Kubernetes-mount alias (no issuer) binding the uc1-retriever-sa login
# to the uc1-agent entity — provider-native vault_identity_entity_alias.
#
# UC2/UC3 = OAuth-resource-server aliases (subject + actor). These carry an
# `issuer` binding that the OAuth resource server REQUIRES (09-DISCOVERY: an alias
# without it validates but then fails JWT auth — issuer is part of the anti-spoof
# actor binding, threat T-09-05-01). The provider resource
# vault_identity_entity_alias exposes ONLY name/mount_accessor/canonical_id — it
# has NO `issuer` field (confirmed against the 5.10.1 schema + provider docs; no
# later 5.x adds it). So the oauth aliases are written via vault_generic_endpoint
# to identity/entity-alias, faithfully replaying the raw write the 09-DISCOVERY
# probe confirmed on the live 2.0.3-ent binary (name=<claim value>, canonical_id,
# mount_accessor, issuer). See 09-05-SUMMARY "Deviations".
#
# mount_accessor is PROVIDED as the synthetic string oauth-resource-server_root_
# <config_id> (09-DISCOVERY MOUNT_ACCESSOR_FORM; the config_id is this profile's
# resource id). depends_on the profile so the synthetic accessor exists first
# (threat T-09-05-05).
################################################################################

# --- UC1 Kubernetes-mount alias (no issuer; provider-native) ---
resource "vault_identity_entity_alias" "uc1_agent" {
  # alias_name_source="serviceaccount_name" on the uc1 role → "<ns>/<sa>".
  name           = "uc1/uc1-retriever-sa"
  mount_accessor = vault_auth_backend.kubernetes.accessor
  canonical_id   = vault_identity_entity.uc1_agent.id
}

locals {
  # Synthetic OAuth-resource-server mount accessor (09-DISCOVERY MOUNT_ACCESSOR_FORM).
  oauth_mount_accessor = "oauth-resource-server_root_${vault_oauth_resource_server_config_profile.ivia.id}"

  # All OAuth entity aliases, keyed by the OAuth claim value (= alias name):
  #   SUBJECT aliases → human `sub` (oscar, jaime) → the human entity.
  #   ACTOR   aliases → agent `act.sub` (agent-uc2, uc3-actor) → the agent entity.
  # jaime appears once (subject side); all four keys are distinct.
  oauth_aliases = merge(
    { for h in local.obo_human_subs : h => vault_identity_entity.human[h].id },
    {
      (var.uc2_agent_identity) = vault_identity_entity.agent_uc2.id
      (var.uc3_agent_identity) = vault_identity_entity.uc3_actor.id
    },
  )
}

# --- UC2/UC3 OAuth subject + actor aliases (issuer-bound; raw write) ---
resource "vault_generic_endpoint" "oauth_alias" {
  for_each = local.oauth_aliases

  path = "identity/entity-alias"
  # identity/entity-alias has no readable-by-name GET and no deletable item URL
  # from this collection path — the documented generic_endpoint identity pattern.
  # Create is an upsert keyed by (mount_accessor, name), so re-apply is idempotent.
  # Alias lifecycle/cleanup is reconciled at the apply wave; workshop teardown
  # destroys the Vault server, so per-alias deletes are moot.
  disable_read         = true
  disable_delete       = true
  ignore_absent_fields = true
  write_fields         = ["id"]

  data_json = jsonencode({
    name        = each.key # human-readable alias name
    external_id = each.key # the OAuth claim value (sub / act.sub) native OBO
    # resolves the entity BY. Vault matches the JWT sub/act.sub against the
    # alias external_id (scoped by issuer), NOT by name — a name-only alias
    # resolves via identity/lookup/entity but fails native OBO with "no alias
    # found". external_id is LOAD-BEARING for the OAuth-resource-server profile.
    canonical_id   = each.value
    mount_accessor = local.oauth_mount_accessor
    issuer         = var.ivia_issuer # = profile issuer_id; REQUIRED for JWT auth
  })

  depends_on = [vault_oauth_resource_server_config_profile.ivia]
}
