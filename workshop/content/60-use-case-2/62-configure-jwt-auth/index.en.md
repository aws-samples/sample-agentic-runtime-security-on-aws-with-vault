---
title: 'Configure the OAuth Resource Server'
weight: 62
---

## Overview

In this module you inspect the Vault **OAuth resource server** — the native mechanism that authorizes Use Case 2's data access — and trace how a user's IVIA-issued OAuth JWT flows into per-user-scoped Postgres credentials **without any intermediate Vault login**.

This is the native cutover: Vault Enterprise treats IVIA's OAuth JWT as a first-class credential. The MCP Server presents that JWT **directly** to Vault in the `X-Vault-Token` header — there is no `POST /v1/auth/jwt/login` round-trip and no separately-issued Vault token. Vault validates the JWT against the OAuth resource server profile, resolves the human subject and the agent actor from the token's claims, and evaluates policy at the moment of the request.

## The Native OAuth Resource Server Model

Use Case 2 authorizes each request on behalf of a human:

```
User OAuth JWT (issued by IVIA — authorization-code grant)
   sub = oscar | jaime         (the human subject)
   aud = agent-uc2             (the OAuth client — the Banking agent)
   act.sub = agent-uc2         (the actor — the agent acting on behalf of the human)
  →  MCP Server presents the JWT to Vault via  X-Vault-Token: <jwt>
  →  Vault validates the JWT against the OAuth resource server profile (IVIA issuer + JWKS)
  →  Vault resolves the human subject entity (from sub) AND the agent actor entity (from act.sub = agent-uc2)
  →  Vault evaluates: human baseline ∩ agent-uc2 ceiling  (∩ optional per-request RAR)
  →  Vault vends a per-user JIT Postgres credential scoped to exactly what that human may read
```

Every successful request resolves **three enforcing controls** for Use Case 2: the human's baseline policy (what this user is permitted), the `agent-uc2` registration's `ceiling_policies` (the maximum the agent may *ever* hold — restrict-only), and an optional per-request authorization-details (RAR) scope. For Use Case 2 the RAR is optional, so when absent the effective grant is **human baseline ∩ agent-uc2 ceiling**.

:::alert{header="Migration: this replaces a hand-rolled jwt auth backend" type="info"}
Earlier iterations of this workshop used a Vault **`jwt` auth backend**: the MCP Server called `POST /v1/auth/jwt/login` with role `uc2-jwt`, Vault matched hand-rolled `bound_claims` / `bound_audiences`, and returned a *separate* Vault token that the server then used to read credentials. That `jwt` auth backend has been **removed**. The before/after:

| | Before (removed) | After (native) |
|---|---|---|
| Auth path | `POST auth/jwt/login` → Vault token, then read creds | Present the OAuth JWT directly via `X-Vault-Token` — one call |
| Who-may-act check | hand-rolled `bound_claims` on the `uc2-jwt` role | agent actor resolved from `act.sub = agent-uc2` against the registry |
| Max-permission envelope | approximated by `bound_*` role fields | `ceiling_policies` on the `agent-uc2` registration (true intersection) |

The old `bound_claims` are shown here only as the *before* of that migration — they are no longer a live control.
:::

## Step 1 — Confirm the jwt backend is gone and the resource server is active

Point the `vault` CLI at Vault with the root token so the reads below are permitted. One paste — kills any prior port-forward, opens a fresh one, and exports `VAULT_ADDR` + `VAULT_TOKEN`:

```bash
pkill -f "kubectl port-forward -n vault svc/vault 8200:8200" 2>/dev/null; kubectl port-forward -n vault svc/vault 8200:8200 >/dev/null 2>&1 & sleep 2 && export VAULT_ADDR=http://localhost:8200 && export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json) && echo "Vault: $VAULT_ADDR"
```

Confirm there is **no** `jwt/` auth mount — the retired backend is gone:

```bash
vault auth list
```

Expected — `kubernetes/` and `token/` only; **no** `jwt/` row:

```
Path           Type          Description
----           ----          -----------
kubernetes/    kubernetes    n/a
token/         token         token based credentials
```

Confirm the Agent Registry secrets engine is mounted (the OAuth resource server profile and the agent registrations live under Enterprise identity):

```bash
vault secrets list | grep -E 'agent-registry|database|aws'
```

Expected — `agent-registry/`, `aws/`, and `database/` are all present.

## Step 2 — Inspect the `agent-uc2` registration and its ceiling

Read the Agent Registry registration that represents the Use Case 2 agent. Its `ceiling_policies` are the restrict-only envelope Vault intersects on every on-behalf-of request:

```bash
vault read agent-registry/agent/agent-uc2
```

Expected (key fields):

```
Key                               Value
---                               -----
display_name                      agent-uc2
ceiling_policies                  [uc2-ceiling]
optional_authorization_details    true
```

- `display_name` `agent-uc2` — the actor identity Vault resolves from the JWT's `act.sub` claim.
- `ceiling_policies` `[uc2-ceiling]` — the maximum this agent may ever hold. It **restricts**; it never grants. The effective grant is the *intersection* of the human's baseline and this ceiling.
- `optional_authorization_details` `true` — a per-request `vault:path_access` RAR is *optional* for Use Case 2 (mandatory for Use Case 3). When absent, enforcement is human baseline ∩ ceiling.

Read the `uc2-ceiling` policy — the paths the agent is *ever* permitted to touch:

```bash
vault policy read uc2-ceiling
```

Expected — the read-only envelope for the personal-data agent:

```hcl
path "database/creds/uc2-personal-readonly" { capabilities = ["read"] }
path "aws/sts/bedrock-reader"               { capabilities = ["read", "update"] }
path "auth/token/lookup-self"               { capabilities = ["read"] }
path "sys/leases/renew"                     { capabilities = ["update"] }
```

Notice what is **absent**: no `database/creds/uc3-refund-writer` and no write-capable credential role. The ceiling cannot be widened at request time — a per-request RAR can only *narrow* it further.

## Step 3 — Inspect the human baseline policy

The human subject (`oscar` or `jaime`) contributes the *baseline* — what this specific user is permitted. Read it:

```bash
vault policy read uc2-personal
```

Expected output:

```hcl
# UC2: Personal-data human baseline (ENFC-02)
path "database/creds/uc2-personal-readonly" { capabilities = ["read"] }
path "aws/sts/bedrock-reader"               { capabilities = ["read", "update"] }
path "auth/token/lookup-self"               { capabilities = ["read"] }
path "sys/leases/renew"                     { capabilities = ["update"] }
```

The effective grant Vault applies is **`uc2-personal` (human baseline) ∩ `uc2-ceiling` (agent ceiling)**. Both must permit a path for the request to succeed. This is ENFC-02 at the Vault layer, expressed as an intersection rather than a single flat policy.

## Step 4 — Verify the database credentials role

```bash
vault read database/roles/uc2-personal-readonly
```

Expected output (key fields):

```
Key                    Value
---                    -----
db_name                workshop-pg
default_ttl            15m
max_ttl                30m
creation_statements    ["CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
                        "ALTER ROLE \"{{name}}\" SET search_path TO banking,public;",
                        "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
                        "GRANT SELECT ON ALL TABLES IN SCHEMA banking TO \"{{name}}\";",
                        "ALTER DEFAULT PRIVILEGES IN SCHEMA banking GRANT SELECT ON TABLES TO \"{{name}}\";"]
```

Each ephemeral role is created with login credentials scoped to the banking schema, read-only, with a 15-minute TTL. There is no permanent Postgres role — grants are applied directly to the ephemeral role, and no INSERT/UPDATE/DELETE is granted.

## Step 5 — Present the OAuth JWT directly to Vault (demo)

To confirm the native path, present a real user JWT to Vault via `X-Vault-Token` and watch Vault vend a credential in a **single** call — no login step.

The Banking UI keeps the user's IVIA-issued JWT in an HttpOnly cookie named `id_token`. To grab it:

1. Sign in to the Banking UI as `oscar` or `jaime`.
2. Open Chrome DevTools (F12) → **Application** tab.
3. Storage → Cookies → click the workshop hostname.
4. Find the row `id_token` and copy the **Value** column.

Then present it as the Vault token — the JWT **is** the credential:

```bash
JWT_TOKEN="<paste-the-id_token-value>"; kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${JWT_TOKEN}' vault read database/creds/uc2-personal-readonly"
```

Expected output — a per-user JIT Postgres credential, issued directly against the presented OAuth JWT:

```
Key                Value
---                -----
lease_id           database/creds/uc2-personal-readonly/<opaque>
lease_duration     15m
lease_renewable    true
password           <ephemeral>
username           v-token-<user>-uc2-pers-<random>-<timestamp>
```

There is no `vault write auth/jwt/login` in that sequence. Vault validated the OAuth JWT against the resource server profile, resolved `sub` (the human) and `act.sub = agent-uc2` (the agent actor), applied `uc2-personal ∩ uc2-ceiling`, and vended the credential — all in the one `database/creds` read. The `username` binds the credential to the resolved identity for the Vault audit trail. The MCP Server uses exactly this credential for the user's session.

:::expand{header="Platform Track — OAuth resource server profile, registration, and ceiling (Terraform)"}

The native model is configured by the `vault_config` Terraform module using Vault Enterprise identity primitives (provider `hashicorp/vault >= 5.10.1`):

```hcl
# Activate the Enterprise feature (idempotent)
resource "vault_activation_flags" "oauth_resource_server" {
  feature = "oauth-resource-server"
}

# One OAuth resource server profile — IVIA issuer + JWKS. user_claim = sub for all OAuth Use Cases.
resource "vault_oauth_resource_server_config_profile" "ivia" {
  # issuer_id / jwks_url resolved from IVIA's OAuth provider
  # user_claim = "sub"
}

# The agent's registry identity + its max-permission ceiling (restrict-only)
resource "vault_agent_registration" "agent_uc2" {
  display_name                   = "agent-uc2"
  ceiling_policies               = [vault_policy.uc2_ceiling.name]
  optional_authorization_details = true   # RAR optional for UC2
}
```

The OAuth JWT is presented in the **`X-Vault-Token`** header (`VAULT_TOKEN=<jwt>`), not through a login endpoint. Vault synthesizes a mount accessor of the form `oauth-resource-server_root_<config_id>` for the profile; the identity aliases bind on the profile `issuer`, not on that accessor.

Each human persona (`oscar`, `jaime`) has its own identity entity with a subject alias keyed on its `sub` value; the agent has an actor alias keyed on `act.sub = agent-uc2`. On an on-behalf-of request Vault resolves **both** — a bare, unregistered human subject never resolves and fails closed. This is why every persona that drives Use Case 2 must be registered.

Key design decision: **Vault validates the JWT signature and resolves identity; the MCP Server does neither.** The MCP Server forwards the token; Vault owns the cryptographic validation and the policy intersection.
:::

:::expand{header="Agent Developer Track — MCP server presents X-Vault-Token directly"}

With the native cutover, the MCP Server's `vault-client.ts` no longer performs a login. It presents the user's OAuth JWT as the Vault token and reads credentials in a single request:

```typescript
export class VaultClient {
  private vaultAddr: string;

  constructor() {
    this.vaultAddr = process.env.VAULT_ADDR ?? 'http://vault.vault.svc.cluster.local:8200';
  }

  // Called once per request with the user's OAuth JWT from the Authorization header
  async getDbCredsForUser(userJwt: string): Promise<{ username: string; password: string; leaseId: string }> {
    // Present the OAuth JWT DIRECTLY via X-Vault-Token — no auth/jwt/login round-trip
    const credsResp = await fetch(
      `${this.vaultAddr}/v1/database/creds/uc2-personal-readonly`,
      { headers: { 'X-Vault-Token': userJwt } },
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
    };
  }
}
```

Removing the login round-trip removes a whole failure mode (a stale or mis-scoped intermediate Vault token) and makes the audit trail exact: the OAuth JWT the user presented is the identity Vault recorded for the `database/creds` issuance.

Per-user identity flows from the JWT straight to the DB connection:

```
HTTP request → Authorization: Bearer <OAuth JWT>
                     ↓
               MCP Server forwards it as X-Vault-Token
                     ↓
               Vault database/creds/uc2-personal-readonly
                     → Vault validates JWT (resource server profile)
                     → resolves sub = "oscar" (human) + act.sub = agent-uc2 (actor)
                     → applies uc2-personal ∩ uc2-ceiling
                     → returns username, password, lease_id
                     ↓
               psql SET app.current_user_sub = 'oscar'   ← RLS filters to Oscar's rows
```
:::

---

### What Would Have Failed

**Without the agent registration (identity failure):** If `agent-uc2` were not registered, Vault could not resolve the actor from `act.sub` and the on-behalf-of request would fail closed — no credential is issued. The registry is the authority on *which* agent is acting.

**With a widened ceiling (least-privilege failure):** If `uc2-ceiling` included `database/creds/uc3-refund-writer`, the personal-data agent could reach a write-capable role. The ceiling is the hard cap: it can only be *narrowed* by a per-request RAR, never widened at request time.

**Without per-request auditing (OBJ-5 failure):** Because the OAuth JWT is presented per request, each `database/creds` issuance carries the exact resolved `sub` and actor. Without that, a specific SELECT could not be attributed to a specific human identity — the access event becomes unattributable.
