---
title: 'Vault Bound Claims Enforcement'
weight: 72
---

## How Vault Enforces Delegation

The Vault `uc3-jwt` auth role rejects any JWT that does not satisfy **all three** bound claims simultaneously. A valid CIBA token without `may_act` is rejected. A valid `may_act` token with the wrong `authorization_details` type is rejected.

```hcl
# vault_config/main.tf — uc3-jwt JWT auth role
resource "vault_jwt_auth_backend_role" "uc3_jwt" {
  backend        = vault_jwt_auth_backend.jwt.path
  role_name      = "uc3-jwt"
  role_type      = "jwt"
  bound_audiences = ["agent-uc3"]

  # RFC 8693 delegation enforcement: the actor must be the Use Case 3 service account
  bound_claims = {
    "may_act/sub" = "service-account:agent-uc3"
    # RFC 9396 RAR enforcement: only refund_approval type unlocks write creds
    "authorization_details/0/type" = "refund_approval"
  }

  user_claim = "sub"
  token_policies = ["uc3-privileged"]
  token_ttl      = 300  # 5 minutes — matches DB role TTL
}
```

## The DB Role: Time-Boxed Write Privileges

The `uc3-refund-writer` Vault database role issues ephemeral credentials that expire after 5 minutes. The PostgreSQL role created at issuance time has only the minimum grants needed for a refund write:

```hcl
# vault_config/main.tf — uc3-refund-writer DB role
resource "vault_database_secret_backend_role" "uc3_refund_writer" {
  backend = vault_database_secret_backend.db.path
  name    = "uc3-refund-writer"
  db_name = vault_database_secret_backend_connection.pg.name

  default_ttl = 300   # 5 minutes
  max_ttl     = 300   # hard ceiling — no renewal

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'",
    "GRANT USAGE ON SCHEMA banking TO \"{{name}}\"",
    "GRANT SELECT, INSERT, UPDATE ON banking.refunds TO \"{{name}}\"",
  ]

  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking FROM \"{{name}}\"",
    "DROP ROLE IF EXISTS \"{{name}}\"",
  ]
}
```

After 5 minutes the role is auto-revoked. Any attempt to reuse the credentials after expiry returns `FATAL: role does not exist`.

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
