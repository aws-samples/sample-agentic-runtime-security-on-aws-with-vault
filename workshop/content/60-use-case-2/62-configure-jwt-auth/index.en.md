---
title: 'Vault JWT Authentication'
weight: 62
---

## Overview

In this module you inspect the Vault `jwt` auth backend configuration that was applied by the `vault_config` Terraform module. You trace the path from a user's IVIA-issued JWT through Vault JWT validation to the issuance of per-user-scoped Postgres credentials.

## The Token Exchange Pattern

Use Case 2 uses Vault's `jwt` auth method as the token exchange mechanism:

```
User JWT (issued by IVIA)
  →  Vault POST /v1/auth/jwt/login  (jwt auth role: uc2-jwt)
  →  Vault validates JWT signature against IVIA JWKS
  →  Vault evaluates bound_audiences claim
  →  Vault issues a short-lived token bound to uc2-personal policy
  →  MCP Server calls GET /v1/database/creds/uc2-personal-readonly
  →  Vault generates per-user JIT Postgres credential
```

This is not RFC 8693 Token Exchange — Vault's `jwt` auth method is the token exchange for this architecture. The user JWT is the proof of identity; Vault translates it into a database credential scoped to exactly what the user is authorized to access.

## Step 1 — Inspect the jwt auth backend configuration

```bash
kubectl exec -n vault vault-0 -- vault read auth/jwt/config
```

Key fields:

| Field | Value | Meaning |
|---|---|---|
| `jwks_url` | IVIA's JWKS endpoint URL | Vault is given the JWKS URL directly rather than an OIDC discovery URL. This is necessary because OIDC discovery validation fails with IVIA's self-signed certificate; providing the JWKS URL directly (paired with `jwks_ca_pem`) bypasses that step. |
| `bound_issuer` | External WRP ALB issuer URL (e.g., `https://<ivia-ingress-hostname>`) | JWT `iss` claim must match this external WRP ALB hostname. The issuer is the public-facing ALB URL, not an in-cluster address. |
| `default_role` | _(empty)_ | Role must be specified explicitly on each login call. |

Vault uses the `jwks_url` to fetch IVIA's public signing keys and cache them for JWT signature validation.

## Step 2 — Inspect the uc2-jwt role

```bash
kubectl exec -n vault vault-0 -- vault read auth/jwt/role/uc2-jwt
```

Expected output (key fields):

```
Key                   Value
---                   -----
bound_audiences       [agent-uc2]
token_policies        [uc2-personal]
token_ttl             1h
token_max_ttl         2h
user_claim            sub
role_type             jwt
```

Explanation of each field:

| Field | Value | Why It Matters |
|---|---|---|
| `bound_audiences` | `[agent-uc2]` | The JWT `aud` claim must contain `agent-uc2` (the IVIA OAuth client ID). Prevents tokens issued for other clients from being used here. |
| `user_claim` | `sub` | Vault extracts the `sub` claim from the JWT and maps it to a Vault entity. This is how per-user identity flows into policy evaluation. |
| `token_policies` | `[uc2-personal]` | Every successful jwt login receives a Vault token bound to this policy. |
| `token_ttl` | `1h` | The Vault token issued after jwt login lives for 1 hour. The downstream DB credential has its own (shorter) TTL. |

## Step 3 — Inspect the uc2-personal policy

```bash
kubectl exec -n vault vault-0 -- vault policy read uc2-personal
```

Expected output:

```hcl
# uc2-personal — scoped policy for per-user read-only banking access
path "database/creds/uc2-personal-readonly" {
  capabilities = ["read"]
}

path "sys/leases/renew" {
  capabilities = ["update"]
}

path "sys/leases/revoke" {
  capabilities = ["update"]
}
```

Note what is absent: no path for `database/creds/uc3-refund-writer` or any write-capable credential role. This policy isolation is ENFC-02 at the Vault layer.

## Step 4 — Verify the database credentials role

```bash
kubectl exec -n vault vault-0 -- vault read database/roles/uc2-personal-readonly
```

Expected output (key fields):

```
Key                    Value
---                    -----
db_name                workshop-pg
default_ttl            15m
max_ttl                1h
creation_statements    ["CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
                        "ALTER ROLE \"{{name}}\" SET search_path TO banking,public;",
                        "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
                        "GRANT SELECT ON ALL TABLES IN SCHEMA banking TO \"{{name}}\";",
                        "ALTER DEFAULT PRIVILEGES IN SCHEMA banking GRANT SELECT ON TABLES TO \"{{name}}\";"]
```

Each ephemeral role is created with login credentials scoped to the banking schema. The `search_path` pin, `GRANT USAGE`, and `GRANT SELECT` statements together restrict the role to read-only access on the banking schema. There is no permanent Postgres role involved — grants are applied directly to the ephemeral role. No INSERT, UPDATE, or DELETE access is granted.

## Step 5 — Perform a live jwt login (demo)

To confirm the jwt auth backend is working, perform a login using a pre-obtained JWT. In the browser, open the developer tools and inspect the `Authorization` header on any API call from the Banking UI to the Banking Agent. Copy the bearer token value.

Then run:

```bash
JWT_TOKEN="<paste-token-here>"

kubectl exec -n vault vault-0 -- \
  vault write auth/jwt/login role=uc2-jwt jwt="${JWT_TOKEN}"
```

Expected output:

```
Key                  Value
---                  -----
token                hvs.CAEIQ...
token_accessor       abcde12345
token_duration       1h
token_policies       [uc2-personal default]
token_meta_sub       oscar
```

The `token_meta_sub` field confirms Vault extracted the `sub` claim from the JWT. Now use that Vault token to fetch DB credentials:

```bash
VAULT_TOKEN="hvs.CAEIQ..."
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_TOKEN=${VAULT_TOKEN} vault read database/creds/uc2-personal-readonly"
```

You will see a Postgres username and password with a 15-minute TTL. This is the credential the MCP Server uses for your session.

:::expand{header="Platform Track — Vault jwt auth role configuration and IVIA OIDC wiring"}

The `uc2-jwt` Vault role is created by the `vault_config` Terraform module:

```hcl
resource "vault_jwt_auth_backend_role" "uc2_jwt" {
  backend         = vault_jwt_auth_backend.ivia.path
  role_name       = "uc2-jwt"
  role_type       = "jwt"
  bound_audiences = ["agent-uc2"]
  user_claim      = "sub"
  token_policies  = ["uc2-personal"]
  token_ttl       = 3600
  token_max_ttl   = 14400
}
```

The `bound_audiences` check is the critical guard: Vault rejects any JWT whose `aud` claim does not include `agent-uc2`. This means tokens issued for IVIA's other OAuth clients (e.g., the Use Case 3 CIBA client) cannot be used to obtain `uc2-personal` credentials.

IVIA JWKS validation happens at the `jwt` auth backend level, not at the role level. Vault fetches IVIA's JWKS from the `jwks_url` and caches the signing keys. Each incoming JWT is verified against these cached keys before the role's `bound_audiences` check runs.

The `jwks_ca_pem` field on the Vault jwt auth backend supplies IVIA's CA certificate PEM, allowing Vault to trust the IVIA JWKS endpoint's self-signed certificate. This is used instead of `insecure_tls` — Vault is given the CA bundle explicitly rather than disabling TLS verification. In production, replace this with a properly signed certificate from a trusted CA.

Key design decision: **Vault validates the JWT signature; the MCP Server does not.** This keeps the MCP Server code simple and puts the cryptographic validation responsibility on Vault, which has battle-tested JWT validation logic.
:::

:::expand{header="Agent Developer Track — MCP server vault-client.ts code walkthrough"}

The MCP Server's `vault-client.ts` handles both the jwt login and the credential issuance in sequence:

```typescript
export class VaultClient {
  private vaultAddr: string;

  constructor() {
    this.vaultAddr = process.env.VAULT_ADDR ?? 'http://vault.vault.svc.cluster.local:8200';
  }

  // Called once per request with the user's JWT from the Authorization header
  async getDbCredsForUser(userJwt: string): Promise<{ username: string; password: string; leaseId: string }> {
    // Step 1: Exchange user JWT for a Vault token via jwt auth
    const loginResp = await fetch(`${this.vaultAddr}/v1/auth/jwt/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ role: 'uc2-jwt', jwt: userJwt }),
    });
    if (!loginResp.ok) {
      const err = await loginResp.json();
      throw new Error(`Vault jwt login failed: ${err.errors?.join(', ')}`);
    }
    const loginData = await loginResp.json();
    const vaultToken = loginData.auth.client_token;
    const userSub = loginData.auth.metadata?.sub;

    // Step 2: Use the Vault token to fetch dynamic DB credentials
    const credsResp = await fetch(
      `${this.vaultAddr}/v1/database/creds/uc2-personal-readonly`,
      { headers: { 'X-Vault-Token': vaultToken } },
    );
    if (!credsResp.ok) {
      const err = await credsResp.json();
      throw new Error(`Vault DB creds failed: ${err.errors?.join(', ')}`);
    }
    const credsData = await credsResp.json();

    return {
      username: credsData.data.username,
      password: credsData.data.password,
      leaseId: credsData.lease_id,
      userSub,   // propagated to Postgres SET app.current_user_sub
    };
  }
}
```

Why is jwt login called on every request instead of caching the Vault token? Caching the token would couple the credential lifetime to the token TTL (1 hour) rather than the request boundary. Per-request login ensures each tool invocation creates a distinct audit trail entry in the Vault log — linking the specific `sub` claim to the specific `database/creds` issuance. This is OBJ-5 at the request level.

Per-user identity flows from JWT `sub` claim through to DB connection:

```
HTTP request → Authorization: Bearer <JWT>
                     ↓
               MCP Server extracts JWT
                     ↓
               Vault jwt login (role=uc2-jwt, jwt=<JWT>)
                     → Vault extracts sub = "oscar"
                     → Vault issues token + metadata.sub
                     ↓
               Vault database/creds/uc2-personal-readonly
                     → returns username, password, lease_id
                     ↓
               psql SET app.current_user_sub = 'oscar'
               psql SELECT * FROM banking.accounts   ← RLS filters to Oscar's rows
```

The `userSub` value returned from `getDbCredsForUser` is stored in the MCP Server's request context and passed to every `SET app.current_user_sub` call before a Postgres query.
:::
