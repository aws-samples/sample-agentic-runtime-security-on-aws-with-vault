---
title: 'The Bypass Test'
weight: 73
---

## What Would Happen Without `may_act` Enforcement?

If Vault's `uc3-jwt` role had no `bound_claims` on `may_act`, any agent that could obtain a CIBA-issued user token could independently perform a refund write — without the user knowing which agent acted. The delegation proof would be meaningless.

The bypass test proves enforcement is working by attempting to present forged tokens and confirming Vault rejects them at the auth layer — before any credential is issued.

## Run the Bypass Test

```bash
cd infrastructure/scripts
./verify-uc3.sh --bypass
```

The script generates two forged JWTs using PyJWT (running in a temporary Kubernetes pod) and presents each to Vault's `auth/jwt/login` endpoint.

**Expected output:**

```
ℹ  Use Case 3 — CIBA Privileged verification — BYPASS TEST MODE

ℹ  Bypass Check 12: Forge JWT with wrong may_act.sub
✓  Bypass Check 12 PASSED: Vault rejected forged may_act.sub — HS256 token not
   trusted by JWKS (signature validation + may_act.sub bound_claim enforcement)

ℹ  Bypass Check 13: Forge JWT with wrong authorization_details type
✓  Bypass Check 13 PASSED: Vault rejected wrong authorization_details type —
   HS256 token not trusted by JWKS (even if may_act.sub matched,
   authorization_details.type must equal refund_approval)

All checks passed.
```

## Two Layers of Rejection

The forged tokens are rejected by Vault for two independent reasons, either of which would be sufficient:

| Layer | Mechanism | What It Enforces |
|---|---|---|
| JWT signature | JWKS validation against IVIA's RS256 public keys | Only IVIA-signed tokens are accepted — HS256 self-signed tokens are always rejected |
| `bound_claims` | `/may_act/sub = "*"` (glob) — any `may_act.sub` value in the JWT satisfies this check; the key constraint is that `may_act` must be present and the token must be IVIA-signed | Only properly delegated RFC 8693 tokens carry `may_act`; a raw CIBA token without delegation is rejected |

The signature layer and the claim layer are both enforced. A real attacker would need to compromise IVIA's RS256 private signing key in order to produce a token that passes JWKS validation — the bound_claim on `/may_act/sub` is an additional structural check that a raw (non-delegated) CIBA token lacks the `may_act` object entirely.

### Threat Model

**What this protects against:** A rogue agent pod that obtains a user's CIBA access token (via network interception or a compromised secret) cannot use it to issue a refund. A raw CIBA access token has no `may_act` object, so the `/may_act/sub` bound_claim check fails — but more fundamentally, the forged HS256 token the bypass test generates is rejected first by JWKS signature validation: Vault trusts only tokens signed by IVIA's RS256 key pair. No DB credentials are ever issued.

**What this does NOT protect against:** A compromised agent-uc3 pod with its service account JWT intact could initiate a CIBA flow and present the resulting delegated token to Vault. Mitigations for pod compromise (e.g., falco runtime rules, IRSA session policy restrictions) are out of scope for this workshop but represent the next layer of defense.

## Read-Path Tenant Isolation

The bypass tests above prove the write path is protected. This section proves the read path is isolated — Jaime can only read Jaime's data, and a request scoped to a different user's account returns no results.

Use Case 3 enforces read isolation through three independent layers:

1. **Row-Level Security (RLS):** The `banking.transactions`, `banking.accounts`, and `banking.refunds` tables carry Postgres RLS policies that filter every SELECT by the `app.current_user_sub` GUC. The agent sets this GUC to the verified `sub` from the bearer token before executing any query.
2. **Vault least-privilege role:** All read operations use the `uc3-readonly` Vault DB role, which carries `GRANT SELECT` only — it cannot INSERT into any banking table.
3. **Owner predicate (defense-in-depth):** `check_refund_status` includes an explicit `JOIN banking.accounts WHERE a.user_sub = <authenticated_sub>` predicate in addition to the GUC/RLS layer.

### Section 1 — Browser Read Isolation

Sign in to the banking application as Jaime and ask the Use Case 3 agent to list your transactions or check a refund status.

1. Open an **Incognito / Private browser window**, go to the banking application URL, and sign in as **jaime** using the IVIA login page.
2. Navigate to the Use Case 3 chat interface and send the message: `List my recent transactions`.
3. Confirm the response contains only Jaime's transaction records (amounts, merchants, account references).
4. Open a **fresh Incognito / Private window**, sign in as **oscar**, and repeat the same query — confirm you see only Oscar's records and zero of Jaime's.

:::alert{type="info" header="Switch personas with Incognito, not Logout"}
IVIA keeps its own SSO session cookie, so **Logout** in the banking app leaves you recognised by IVIA and re-opening the app jumps to the OAuth consent page rather than a fresh login. Use a separate Incognito / Private window per persona — each starts with an empty cookie jar and gives you a clean login.
:::

A refund lookup works the same way: ask `What is the status of refund <jaime-refund-id>` while signed in as Oscar — the agent returns "Refund not found" with no detail about Jaime's refund (no information disclosure).

### Section 2 — Postgres GUC and RLS Assertion

This section lets you prove RLS is active at the database layer independently of the agent. You will obtain a `uc3-readonly` Vault credential, connect to RDS, set the `app.current_user_sub` GUC to each user's sub, and observe that `SELECT count(*)` returns only that user's rows.

#### Step 2.1 — Obtain a Vault uc3-readonly credential

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
CREDS_JSON=$(kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read database/creds/uc3-readonly -format=json")

echo "$CREDS_JSON" | jq '{username: .data.username, password: .data.password}'

export PG_USER=$(echo "$CREDS_JSON" | jq -r '.data.username')
export PG_PASS=$(echo "$CREDS_JSON" | jq -r '.data.password')
export RDS_HOST=$(kubectl get configmap uc3-agent-config -n banking-app -o jsonpath='{.data.DB_HOST}')
```

:::alert{type="warning" header="Credential TTL: 15 minutes"}
The `uc3-readonly` credential expires after 15 minutes. If you see `psql: FATAL: password authentication failed`, re-run Step 2.1 to mint a fresh credential.
:::

#### Step 2.2 — Confirm RLS scoping by sub

Spawn a transient `postgres:16-alpine` pod, set the `app.current_user_sub` GUC to Jaime's sub, and count her transactions. Then repeat for Oscar's sub and observe the counts differ.

Replace `<jaime-sub>` and `<oscar-sub>` with the IVIA `sub` values for each user (visible in the IVIA LMI user profile or from a decoded id_token):

```bash
# Count Jaime's transactions
kubectl run pg-rls-test --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "SELECT set_config('app.current_user_sub', '<jaime-sub>', false);
        SELECT count(*) AS jaime_tx_count FROM banking.transactions;"
```

```bash
# Count Oscar's transactions — should differ from Jaime's count
kubectl run pg-rls-test2 --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "SELECT set_config('app.current_user_sub', '<oscar-sub>', false);
        SELECT count(*) AS oscar_tx_count FROM banking.transactions;"
```

Each query returns only the row count for the specified sub — cross-tenant rows are invisible. This is the RLS policy (`user_accounts` USING clause) enforcing isolation at the Postgres layer, independently of the agent.

### Section 3 — Least-Privilege: INSERT is Denied

The `uc3-readonly` role carries `GRANT SELECT` only. The same credential used in Step 2.1 cannot write to the banking tables.

```bash
kubectl run pg-insert-uc3 --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "INSERT INTO banking.refunds (account_id, amount, status, request_id)
         VALUES ('00000000-0000-0000-0000-000000000000', 1.00, 'pending', gen_random_uuid());"
```

Expected output:

```
ERROR:  permission denied for table refunds
pod "pg-insert-uc3" deleted
```

The Postgres GRANT layer rejects the INSERT before the RLS policy is even evaluated. This confirms that a bug in the agent code that accidentally attempted a write would fail closed at the database layer — Vault's `uc3-readonly` role has no write capability.

### Section 4 — Hostile Read Attempt

With a valid authenticated session as Jaime, ask the Use Case 3 agent to look up an account or refund that belongs to Oscar:

1. Sign in as **jaime** (use a fresh Incognito / Private window so you get a clean login — see the note in Section 1).
2. In the Use Case 3 chat, send: `Check refund status for refund ID <oscar-refund-id>`.
3. The agent returns: `{"error": "Refund <id> not found"}` — no detail about Oscar's refund is disclosed.

This demonstrates the owner-predicate defense-in-depth layer: `check_refund_status` includes `JOIN banking.accounts WHERE a.user_sub = <authenticated_sub>`, so a cross-user refund ID returns the same "not found" response as a non-existent ID — no information about the existence or value of Oscar's refunds leaks to Jaime.

The same behavior applies to `list_transactions` and `_check_account_owner`: both set `app.current_user_sub` to the verified `sub` from the bearer token before querying, so RLS filters cross-tenant rows before they reach the agent.
