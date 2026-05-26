---
title: 'Vault Bound Claims Enforcement'
weight: 72
---

## How Vault Enforces Delegation

The Vault `uc3-jwt` auth role rejects any JWT that does not satisfy **both** bound conditions simultaneously: the correct audience AND the `may_act` delegation claim. A valid CIBA token without `may_act` is rejected.

```hcl
# vault_config/main.tf — uc3-jwt JWT auth role
resource "vault_jwt_auth_backend_role" "uc3_jwt" {
  backend        = vault_jwt_auth_backend.ivia.path
  role_name      = "uc3-jwt"
  role_type      = "jwt"
  bound_audiences = ["uc3-actor"]

  # RFC 8693 delegation enforcement: any actor sub passes the glob check.
  # Tighten to "uc3-actor" if a single fixed actor is desired.
  bound_claims_type = "glob"
  bound_claims = {
    "/may_act/sub" = "*"
  }

  # Audit-only metadata (NOT enforcement). claim_mappings writes nested JWT
  # claims into auth.metadata for three-plane audit correlation (OBJ-4/OBJ-5).
  # authorization_details[0].type is captured here as rar_type — it is NOT
  # a bound_claim and is NOT an authorization gate.
  claim_mappings = {
    "/may_act/sub"                  = "may_act_sub"
    "/authorization_details/0/type" = "rar_type"
  }

  user_claim = "sub"
  token_policies = ["uc3-privileged"]
  token_ttl      = 3600
}
```

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
The `uc3-privileged` Vault policy permits the token holder to read DB credentials from `uc3-refund-writer` only. No other paths are permitted:

```hcl
# vault_config/policies/uc3-privileged.hcl
path "database/creds/uc3-refund-writer" {
  capabilities = ["read"]
}
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
