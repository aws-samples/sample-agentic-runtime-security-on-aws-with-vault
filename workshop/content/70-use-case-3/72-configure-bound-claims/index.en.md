---
title: 'Vault Bound Claims Enforcement'
weight: 72
---

## How Vault Enforces Delegation

The Vault `uc3-jwt` auth role rejects any JWT that does not satisfy **all** of its bound conditions simultaneously: the correct audience (`uc3-actor`), the `may_act` delegation claim (`/may_act/sub` = `uc3-actor`, RFC 8693), **and** the RAR type (`/authorization_details/0/type` = `refund_approval`, RFC 9396). A valid CIBA token without `may_act` is rejected; so is a delegated token carrying any RAR type other than `refund_approval`. Both the delegation claim and the RAR type are stamped onto the exchanged token by the `isvaop_pretoken` mapping rule (covered on the [previous page](../71-ciba-approval-flow/)) and matched here with JSONPointer keys.

```hcl
# vault_config/main.tf — uc3-jwt JWT auth role
resource "vault_jwt_auth_backend_role" "uc3_jwt" {
  backend         = vault_jwt_auth_backend.ivia.path
  role_name       = "uc3-jwt"
  role_type       = "jwt"
  token_policies  = ["uc3-refund-writer"]
  token_ttl       = 3600
  token_max_ttl   = 7200
  bound_audiences = ["uc3-actor"]
  user_claim      = "sub"

  # TWO enforced bindings on the exchanged token, both injected by the
  # isvaop_pretoken mapping rule and matched here with JSONPointer keys (Vault
  # cannot match a map- or array-valued claim directly). Values are literals
  # (no wildcards), so the glob match is EXACT — Vault denies DB write creds
  # unless BOTH match. This is the OBJ-4 enforcement gate.
  #   /may_act/sub                  = uc3-actor       (RFC 8693 — WHO may act)
  #   /authorization_details/0/type = refund_approval (RFC 9396 RAR — WHAT class)
  bound_claims_type = "glob"
  bound_claims = {
    "/may_act/sub"                  = "uc3-actor"
    "/authorization_details/0/type" = "refund_approval"
  }

  # Audit-only metadata extraction (OBJ-4 / OBJ-5 three-plane correlation).
  # claim_mappings writes these nested JWT claims into auth.metadata at jwt
  # login so they surface in the Vault audit log. The SAME two claims are
  # enforced above as bound_claims; here they are ALSO captured for the
  # forensic audit_correlation row (vault_bound_claim_may_act / rar_type).
  claim_mappings = {
    "/may_act/sub"                  = "may_act_sub"
    "/authorization_details/0/type" = "rar_type"
  }
}
```

:::alert{header="Why the approved amount is not bound here" type="info"}
You will notice the role binds the RAR **type** (`refund_approval`) but **not** the approved amount. ISVAOP 25.10 does not expose the consent-time `authorization_details` (with its amount/currency) to any mapping rule at the token-exchange stage, so the amount cannot be stamped as a claim for Vault to validate — and Vault `bound_claims` are string/glob matches that cannot range-check a number regardless. The amount is consent-bound instead by three-plane audit correlation on `request_id` (see the [Three-Plane Audit Correlation](../74-three-plane-audit/) page). `refund_approval` is the genuine, allowlisted, only RAR type `agent-uc3` is permitted to request (provider `authorization_details_types_supported`) — not a placeholder.
:::

## The DB Role: Time-Boxed Write Privileges

The `uc3-refund-writer` Vault database role issues ephemeral credentials with a default lifetime of 5 minutes (renewable up to a hard ceiling of 10 minutes). The PostgreSQL role created at issuance time has only the minimum grants needed for a refund write:

```hcl
# vault_config/main.tf — uc3-refund-writer DB role
resource "vault_database_secret_backend_role" "uc3_refund_writer" {
  backend     = vault_mount.database.path
  name        = "uc3-refund-writer"
  db_name     = vault_database_secret_backend_connection.pg.name

  default_ttl = 300 # 5 minutes
  max_ttl     = 600 # 10 minutes — renewals permitted up to this ceiling

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
```

After the credential lease expires the PostgreSQL role is dropped. Any attempt to reuse the credentials after expiry returns `FATAL: role does not exist`.

:::expand{header="Platform Track — Policy that links auth to DB credential issuance"}
The `uc3-refund-writer` Vault policy (defined inline in `vault_config/main.tf`, attached to the `uc3-jwt` role via `token_policies`) permits the token holder to read the time-boxed write credential — plus the minimal supporting paths the agent needs (read-only DB creds, the Bedrock and CloudWatch STS roles, token self-lookup, and lease renewal):

```hcl
# vault_config/main.tf — vault_policy.uc3_refund_writer
path "database/creds/uc3-refund-writer" { capabilities = ["read"] }
path "database/creds/uc3-readonly"      { capabilities = ["read"] }
path "aws/sts/bedrock-reader"           { capabilities = ["read", "update"] }
path "aws/sts/uc3-logs-writer"          { capabilities = ["read", "update"] }
path "auth/token/lookup-self"           { capabilities = ["read"] }
path "sys/leases/renew"                 { capabilities = ["update"] }
```

The Kubernetes auth role `uc3` (separate from the JWT role) permits the Use Case 3 agent's service account to authenticate and obtain a Vault token for the initial CIBA initiation flow. The JWT role `uc3-jwt` is used for the delegated token exchange result.
:::

:::expand{header="Agent Dev Track — Using the time-boxed credentials"}
After Vault login succeeds, the Use Case 3 agent reads DB credentials and uses them for a single database operation:

```python
# auth.py — exchange delegated JWT for Vault token, then fetch DB creds
vault_resp = requests.post(f"{VAULT_ADDR}/v1/auth/jwt/login",
    json={"role": "uc3-jwt", "jwt": delegated_jwt})
vault_token = vault_resp.json()["auth"]["client_token"]

creds_resp = requests.get(f"{VAULT_ADDR}/v1/database/creds/uc3-refund-writer",
    headers={"X-Vault-Token": vault_token})
db_user = creds_resp.json()["data"]["username"]
db_pass = creds_resp.json()["data"]["password"]

# Write refund using JIT credentials
conn = psycopg2.connect(host=RDS_HOST, dbname="workshop",
    user=db_user, password=db_pass)
```

The credentials are never cached; a new pair is fetched for each approved refund request.
:::

## Verification

```bash
# Confirm uc3-jwt role bound_claims
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="$(cat ~/vault-init.json | jq -r .root_token)" \
  vault read auth/jwt/role/uc3-jwt

# Confirm uc3-refund-writer DB role TTL
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="$(cat ~/vault-init.json | jq -r .root_token)" \
  vault read database/roles/uc3-refund-writer

# Manually test JIT credential issuance
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="$(cat ~/vault-init.json | jq -r .root_token)" \
  vault read database/creds/uc3-refund-writer
```

The output will show a dynamic username/password pair with `lease_duration` of 5 minutes. Repeat the command after 5 minutes — the previous credentials will be gone.
