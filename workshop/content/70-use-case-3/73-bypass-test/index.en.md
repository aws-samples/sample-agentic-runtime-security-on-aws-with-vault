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

The script runs **two genuine negative tests**, each classified by the *reason* Vault rejected the login — so the test can never silently pass on an infrastructure error:

- **Check 14 (signature control):** forges an HS256 JWT (PyJWT, in a temporary pod) and presents it. Vault trusts only IVIA's RS256 JWKS, so it dies at the signature layer.
- **Check 15 (bound-claim teeth):** mints a **genuine, IVIA-signed** `uc3-actor` `client_credentials` token. It sails past the RS256 signature and `aud=uc3-actor` checks, but a plain `client_credentials` grant has **no** `may_act` claim (that is injected only during token-exchange), so Vault rejects it at the `/may_act/sub` bound_claim. This proves the `bound_claims` actually gate access — not merely the signature.

**Expected output** (captured from a live run):

```
  ℹ INFO Use Case 3 — CIBA Privileged verification — BYPASS TEST MODE

  ℹ INFO Bypass Check 14: Untrusted-signer control — HS256 self-forged JWT must be rejected at the signature layer
  ✓ PASS Bypass Check 14 PASSED: Vault rejected the HS256 self-forged JWT at the signature layer (trusts only IVIA's RS256 JWKS) — an attacker cannot forge their way in

  ℹ INFO Bypass Check 15: Bound-claim enforcement — real IVIA-signed uc3-actor token (no may_act) must be rejected at /may_act/sub
  ✓ PASS Bypass Check 15 PASSED: Vault accepted the token's RS256 signature + aud=uc3-actor but REJECTED it at the /may_act/sub bound_claim (no may_act delegation present) — bound_claims are enforced, not just the signature

===============================================================================
 ✓ 2 check(s) passed
===============================================================================
```

## Two Layers of Rejection

The two tests prove rejection at two independent layers, either of which is sufficient on its own:

| Layer | Mechanism | What It Enforces |
|---|---|---|
| JWT signature | JWKS validation against IVIA's RS256 public keys | Only IVIA-signed tokens are accepted — HS256 self-signed tokens are always rejected (Check 14) |
| `bound_claims` | `/may_act/sub = "uc3-actor"` AND `/authorization_details/0/type = "refund_approval"` (both EXACT, glob type, no wildcards) | Evaluated **only after** the signature passes: the token's claims must match exactly — `may_act.sub = uc3-actor` (delegation) AND `authorization_details[0].type = refund_approval` (RAR type). A genuine IVIA-signed token that lacks `may_act` — or carries a different RAR type — is rejected here even though its signature is valid (Check 15) |

Both layers are enforced. Check 14 proves you cannot forge your way past the signature; Check 15 proves the `bound_claims` have teeth — a real IVIA-signed token is still rejected when it lacks the required `may_act` delegation. A delegated token carrying any RAR `type` other than `refund_approval` is rejected the same way.

:::alert{header="Why there is no negative test for a wrong RAR type" type="info"}
The `/authorization_details/0/type` binding is enforced (you can see it on the live `uc3-jwt` role and in `vault_config/main.tf`), but the bypass script does not include a standalone negative test for it. To exercise it you would need a genuine IVIA-signed token that has `may_act` present **but** a different RAR type — and the only way to obtain a `may_act` claim is the token-exchange grant, which the `isvaop_pretoken` rule always stamps with `type=refund_approval`. There is no documented path in ISVAOP 25.10 to mint a token with `may_act` present and a forged type, so a faithful negative test is not feasible without compromising IVIA's signing key. The binding is real; the absence of a forge-based test is a property of the platform, not a gap in enforcement.
:::

### Threat Model

**What this protects against:** A rogue agent pod that obtains a user's CIBA access token (via network interception or a compromised secret) cannot use it to issue a refund. A raw CIBA access token has no `may_act` object, so the `/may_act/sub` bound_claim check fails (Check 15) — and a self-forged token is rejected even earlier, at JWKS signature validation, because Vault trusts only tokens signed by IVIA's RS256 key pair (Check 14). No DB credentials are ever issued.

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

The value RLS filters on is the IVIA `sub` claim, seeded as the plain strings `oscar` and `jaime` (`seed.sql`, column `banking.accounts.user_sub`). You do **not** need to look anything up in the IVIA LMI or decode an id_token — use those two values directly.

Spawn **one** transient `postgres:16-alpine` pod. In a single `psql` session, set the `app.current_user_sub` GUC to each user in turn and count their transactions. RLS returns only the rows owned by whichever `sub` is currently active:

```bash
kubectl run pg-rls-test --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop -c "
    SELECT set_config('app.current_user_sub','jaime',false);
    SELECT 'jaime' AS acting_as, count(*) AS tx_count FROM banking.transactions;
    SELECT set_config('app.current_user_sub','oscar',false);
    SELECT 'oscar' AS acting_as, count(*) AS tx_count FROM banking.transactions;"
```

**Expected output** — each `set_config` line echoes the `sub` it just activated, and the two `tx_count` rows differ (Jaime owns 9 transactions, Oscar owns 8):

```
 set_config
------------
 jaime
(1 row)

 acting_as | tx_count
-----------+----------
 jaime     |        9
(1 row)

 set_config
------------
 oscar
(1 row)

 acting_as | tx_count
-----------+----------
 oscar     |        8
(1 row)
```

Each count includes only the active `sub`'s rows — cross-tenant rows are invisible. This is the RLS policy (the `USING (user_sub = current_setting('app.current_user_sub', true))` clause) enforcing isolation at the Postgres layer, independently of the agent. The pod is deleted automatically (`--rm`) when the query finishes.

### Section 3 — Least-Privilege: INSERT is Denied

The `uc3-readonly` role carries `GRANT SELECT` only. The same credential used in Step 2.1 cannot write to the banking tables.

The `INSERT` below names **only real `banking.refunds` columns** (`account_id, transaction_id, amount, approved_by, request_id` — see `seed.sql`), so it is schema-valid. That matters: Postgres checks table privileges *before* it evaluates column names, NOT NULL/foreign-key constraints, or RLS — so the **only** reason this can fail is the missing `INSERT` privilege. (A typo'd column would instead fail with a schema error and prove nothing.)

```bash
kubectl run pg-insert-uc3 --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "INSERT INTO banking.refunds (account_id, transaction_id, amount, approved_by, request_id)
         VALUES ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000', 1.00, 'least-priv-test', gen_random_uuid());"
```

Expected output:

```
ERROR:  permission denied for table refunds
pod "pg-insert-uc3" deleted
```

`psql` exits non-zero, so `kubectl` may also print `pod "banking-app/pg-insert-uc3" terminated (Error)` — that is expected; the non-zero exit **is** the INSERT being correctly rejected.

The Postgres GRANT layer rejects the INSERT before the RLS policy (or any constraint) is even evaluated. This confirms that a bug in the agent code that accidentally attempted a write would fail closed at the database layer — Vault's `uc3-readonly` role has no write capability.

### Section 4 — Hostile Read Attempt (Owner Predicate)

RLS is not the only layer scoping refund reads. The `check_refund_status` tool adds an explicit **owner predicate** — it `JOIN banking.accounts` and requires `a.user_sub = <authenticated_sub>` — so a `refund_id` you do not own returns the **same** empty result as a non-existent one. The agent reports `{"error": "Refund <id> not found"}` either way, leaking nothing about another user's refunds. This section proves that predicate at the database layer with the `uc3-readonly` credential from Step 2.1, running the exact query the agent runs (`uc3-agent/app/agent.py`, `check_refund_status`).

Refunds are **created by you** during the CIBA approval flow (page 71) — they are never seeded — so the IDs below are examples from one run; **yours will differ.**

#### Step 4.1 — Find a refund you created

A refund is visible only to its owner (RLS), so list refunds under each persona you ran a refund as:

```bash
kubectl run pg-find-refund --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop -c "
    SELECT set_config('app.current_user_sub','oscar',false);
    SELECT 'oscar' AS persona, refund_id, amount::float AS amount FROM banking.refunds;
    SELECT set_config('app.current_user_sub','jaime',false);
    SELECT 'jaime' AS persona, refund_id, amount::float AS amount FROM banking.refunds;"
```

**Example output** — one refund created as each persona (what you see depends on what you approved on page 71):

```
 persona |              refund_id               | amount
---------+--------------------------------------+--------
 oscar   | c2e9db60-f785-4498-b3a5-5109f99eae30 |     45
(1 row)

 persona |              refund_id               | amount
---------+--------------------------------------+--------
 jaime   | 2b2dd8b1-6724-4aa4-820a-c8a0301dbd34 |     65
(1 row)
```

Pick **one** `refund_id`, note which persona owns it, and set three variables (paste **your** values):

```bash
export REFUND_ID=<a refund_id from the output above>
export OWNER=<the persona it appeared under: oscar or jaime>
export ATTACKER=<the other persona>
```

#### Step 4.2 — Cross-owner read returns nothing; owner read returns the row

Run the exact owner-predicate JOIN `check_refund_status` executes — first as the **other** persona (the hostile reader), then as the **owner**:

```bash
kubectl run pg-owner-test --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop -c "
    SELECT set_config('app.current_user_sub','${ATTACKER}',false);
    SELECT 'hostile cross-owner read' AS test, r.refund_id, r.amount::float AS amount
      FROM banking.refunds r
      JOIN banking.accounts a ON a.id = r.account_id
     WHERE r.refund_id = '${REFUND_ID}' AND a.user_sub = '${ATTACKER}';
    SELECT set_config('app.current_user_sub','${OWNER}',false);
    SELECT 'owner read' AS test, r.refund_id, r.amount::float AS amount
      FROM banking.refunds r
      JOIN banking.accounts a ON a.id = r.account_id
     WHERE r.refund_id = '${REFUND_ID}' AND a.user_sub = '${OWNER}';"
```

**Expected output** — the hostile cross-owner read returns **0 rows**; the owner read returns the single row (this example used `OWNER=oscar`, `ATTACKER=jaime`, the $45 refund):

```
 set_config
------------
 jaime
(1 row)

 test | refund_id | amount
------+-----------+--------
(0 rows)

 set_config
------------
 oscar
(1 row)

    test    |              refund_id               | amount
------------+--------------------------------------+--------
 owner read | c2e9db60-f785-4498-b3a5-5109f99eae30 |     45
(1 row)
```

The cross-owner read returns zero rows because of the `AND a.user_sub = <authenticated_sub>` predicate — the same one `check_refund_status` applies on every call. That is why asking the agent for a refund you don't own returns `{"error": "Refund <id> not found"}` instead of another user's data: a cross-tenant refund is made indistinguishable from one that does not exist (no information disclosure). `list_transactions` and account lookups use the same pattern — they set `app.current_user_sub` to the verified `sub` from the bearer token before querying, so RLS filters cross-tenant rows before they ever reach the agent.
