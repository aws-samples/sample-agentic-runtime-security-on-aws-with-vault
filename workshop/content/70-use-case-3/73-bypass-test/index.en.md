---
title: 'The Bypass Test'
weight: 73
---

**Objective 4 · Enforcement at the point of use.** Every page so far built the approval path. This one tries to get round it — and every route fails at Vault, not in the application code.

## Run the bypass test

**Why:** Everything so far has been the happy path. Now we attack it three ways: forge the signature, act as the wrong agent, and ask for a path the token does not name. All three have to fail before any credential is issued.

```bash
cd infrastructure/scripts && ./verify-uc3.sh --bypass
```

The script first **self-mints a real delegated token** — it drives an actual CIBA approval with a
virtual authenticator and performs the RFC 8693 exchange, so every check below runs against a
genuine IVIA-issued token rather than a fixture. That step takes two to four minutes; the persona
it mints for (`oscar` or `jaime`) varies by run and does not change any result.

Each check is then classified by the *reason* Vault rejected the request, so a check can never
silently pass on an infrastructure error:

- **Untrusted-signer control (Check 14):** forges an HS256 JWT (PyJWT, in a temporary pod) whose claims are *identical* to the allowed token — only the signature differs. Vault trusts only IVIA's RS256 JWKS via the resource server profile, so the token dies at the signature layer and the denial is attributable to the signer alone.
- **Positive control (Checks 15–16):** the real delegated token carries a `jti` and `act.sub=uc3-actor`, and is **allowed** to read `database/creds/uc3-refund-writer`. A bypass suite with no positive control cannot tell "correctly denied" from "broken".
- **Wrong-RAR-path control (Check 17 — the money shot):** the *same* valid token, presented to `database/creds/uc3-readonly` — a path its `vault:path_access` RAR does not name. Vault denies with `RAR_NO_MATCH` even though the human baseline and the agent ceiling both permit that path.
- **Wrong-agent control (Check 18):** a genuine UC2 token for the same human, carrying `act.sub=agent-uc2`. The signature, issuer and human all check out, but `agent-uc2`'s ceiling omits the refund path, so the on-behalf-of intersection blocks a UC2 agent from reaching UC3's privileged credential.
- **Client-allowlist control (Check 20):** the identical token-exchange request is refused as `agent-uc2` with `unauthorized_client`, while `uc3-actor` gets past the client gate — delegation cannot be requested by any client that merely reaches the endpoint.

**Expected output** — eight checks pass, and **one check is deliberately skipped**:

```
  ℹ INFO Use Case 3 — CIBA Privileged verification — BYPASS TEST MODE

  ℹ INFO Self-mint: obtaining a REAL delegated OBO token for 'oscar' — driving an ACTUAL approval with a virtual authenticator, then RFC 8693 token-exchange (all secrets sourced at runtime). Takes ~2-4 minutes.
  ✓ PASS Self-mint: minted a real IVIA-issued delegated token + subject token for 'oscar'

  ✓ PASS Bypass Check 14 PASSED: Vault rejected the HS256 forgery whose claims match the ALLOWED delegated token (iss/aud/sub/act.sub/RAR identical) — only the signature differs ...
  ✓ PASS Bypass Check 15: REAL delegated token carries a jti claim (sub=oscar, jti=<uuid>)
  ✓ PASS Bypass Check 15: REAL delegated token carries act.sub=uc3-actor (OBO actor claim Vault resolves)
  ✓ PASS Bypass Check 16 PASSED: the delegated token ... was ALLOWED to read database/creds/uc3-refund-writer ...
  ✓ PASS Bypass Check 17 PASSED: the delegated token (RAR path=database/creds/uc3-refund-writer) was DENIED reading database/creds/uc3-readonly with RAR_NO_MATCH even though the entity ACL + agent ceiling permit it
  ✓ PASS Bypass Check 18 PASSED: the agent-uc2 UC2 token (sub=oscar, act.sub=agent-uc2) was DENIED reading database/creds/uc3-refund-writer — agent-uc2's ceiling omits the refund path ...
  ⚠ WARN Bypass Check 19: SKIPPED — no UC3_WRONG_ACTOR_TOKEN supplied ...
  ✓ PASS Bypass Check 20 PASSED: an identical exchange request was refused as agent-uc2 with unauthorized_client ... while uc3-actor got past the client gate

===============================================================================
 ✓ 8 check(s) passed
===============================================================================
```

:::alert{type="info" header="The ⚠ WARN on Check 19 is expected — it is not a failure"}
Check 19 wants a token that is **validly signed by IVIA** but names a *wrong, unregistered* actor
in `act.sub`. Your IVIA cannot produce one: it only ever signs `act.sub=uc3-actor`, so the token
would have to be supplied by an operator with signing access. The check is therefore optional and
not required for green — and nothing is lost, because Check 18 already proves the actor claim is
load-bearing by denying a genuine token whose actor is a *different registered* agent. If you do
have such a token, set `UC3_WRONG_ACTOR_TOKEN` and re-run to exercise it.
:::

## Three independent denials, each sufficient on its own

| Layer | Mechanism | What It Enforces |
|---|---|---|
| JWT signature | JWKS validation against IVIA's RS256 public keys (resource server profile) | Only IVIA-signed tokens are accepted — HS256 self-signed tokens are always rejected |
| Agent actor | `act.sub` resolved against the Agent Registry, then that agent's `ceiling_policies` intersected with the human baseline | The actor claim decides what the token can reach. Check 18 proves it with a genuine token whose actor is a *different registered* agent (`agent-uc2`): same human, same signature, denied — because `agent-uc2`'s ceiling omits the refund path. An **unregistered** actor resolves to no entity at all and fails closed even earlier |
| Per-request RAR | `vault:path_access` path must match the requested path | Evaluated in Vault at the point of use: a delegated token whose RAR names a different path is denied **even though baseline ∩ ceiling permit the target** |

The RAR-path control is the one that proves enforcement moved *into* Vault: the baseline and the ceiling both allow `database/creds/uc3-refund-writer`, yet Vault still denies the request when the per-request RAR does not name that exact path.

:::alert{type="info" header="What this does not protect against"}
A compromised agent pod with its service account JWT intact could initiate a CIBA flow and present the resulting delegated token to Vault. Mitigations for pod compromise — runtime rules, session policy restrictions — are the next layer of defense and out of scope here.
:::

## Row-level security holds on the read path too

**Why:** Approval protects the write. This checks the read — one legitimate credential, two customers, and neither can see the other's money.

### In the browser

1. Open an **Incognito / Private browser window**, go to the banking application URL, and sign in as **jaime** using the IVIA login page.
2. Navigate to the Use Case 3 chat interface and send the message: `List my recent transactions`.
3. Confirm the response contains only Jaime's transaction records (amounts, merchants, account references).
4. Open a **fresh Incognito / Private window**, sign in as **oscar**, and repeat the same query — confirm you see only Oscar's records and zero of Jaime's.

:::alert{type="info" header="Switch personas with Incognito, not Logout"}
IVIA keeps its own SSO session cookie, so **Logout** in the banking app leaves you recognized by IVIA and re-opening the app jumps to the OAuth consent page rather than a fresh login. Use a separate Incognito / Private window per persona — each starts with an empty cookie jar and gives you a clean login.
:::

A refund lookup works the same way: ask `What is the status of refund <jaime-refund-id>` while signed in as Oscar — the agent returns "Refund not found" with no detail about Jaime's refund (no information disclosure).

### Now prove it without the agent in the path

**Why:** The browser result could be the application filtering for you. Do it yourself against the database, with a real credential, and see the filter is in Postgres.

#### Get a read-only credential

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

#### Count transactions as each persona

The value RLS filters on is the IVIA `sub` claim, seeded as the plain strings `oscar` and `jaime` (`seed.sql`, column `banking.accounts.user_sub`). You do **not** need to look anything up in the IVIA LMI or decode an id_token — use those two values directly.

Spawn **one** transient `postgres:16-alpine` pod. In a single `psql` session, set the `app.current_user_sub` GUC to each user in turn and count their transactions. RLS returns only the rows owned by whichever `sub` is currently active:

```bash
kubectl delete pod pg-rls-test -n banking-app --ignore-not-found --now >/dev/null 2>&1
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

## The read-only credential cannot write

**Why:** The agent holds two credentials. This is the one it uses to look things up — if it could also write, the approval step would be theatre.

The `uc3-readonly` role carries `GRANT SELECT` only. The same credential used in Step 2.1 cannot write to the banking tables.

The `INSERT` below names **only real `banking.refunds` columns** (`account_id, transaction_id, amount, approved_by, request_id` — see `seed.sql`), so it is schema-valid. That matters: Postgres checks table privileges *before* it evaluates column names, NOT NULL/foreign-key constraints, or RLS — so the **only** reason this can fail is the missing `INSERT` privilege. (A typo'd column would instead fail with a schema error and prove nothing.)

```bash
kubectl delete pod pg-insert-uc3 -n banking-app --ignore-not-found --now >/dev/null 2>&1
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

## Knowing a refund id gets you nothing

**Why:** A refund id is not a secret — it sits in the chat transcript. So hand it to the wrong customer and check they still get zero rows.

RLS is not the only layer scoping refund reads. The `check_refund_status` tool adds an explicit **owner predicate** — it `JOIN banking.accounts` and requires `a.user_sub = <authenticated_sub>` — so a `refund_id` you do not own returns the **same** empty result as a non-existent one. The agent reports `{"error": "Refund <id> not found"}` either way, leaking nothing about another user's refunds. This section proves that predicate at the database layer with the `uc3-readonly` credential from Step 2.1, running the exact query the agent runs (`uc3-agent/app/agent.py`, `check_refund_status`).

Refunds are **created by you** during the CIBA approval flow (page 71) — they are never seeded — so the IDs below are examples from one run; **yours will differ.**

#### Step 4.1 — Find a refund you created

A refund is visible only to its owner (RLS), so list refunds under each persona you ran a refund as:

```bash
kubectl delete pod pg-find-refund -n banking-app --ignore-not-found --now >/dev/null 2>&1
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
kubectl delete pod pg-owner-test -n banking-app --ignore-not-found --now >/dev/null 2>&1
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

## One approval pays once

**Why:** A tap on a phone authorizes one refund. A five-minute credential limits how *long* the agent can write, not how *many times* — so replay needs its own answer. Two layers give one:

| Layer | Mechanism | What it stops |
|---|---|---|
| Agent | `complete_refund` re-reads the terms recorded when the approval was requested and refuses if the `request_id` or the approver does not match (`applications/uc3-agent/app/agent.py`) | A refund being completed under an approval that was granted for different terms |
| Database | `refunds_request_id_key` — a unique index on `banking.refunds (request_id)` (`applications/banking-app/db/seed.sql`) | A second refund row ever existing for one approval, even if the agent is bypassed entirely |

You exercise the **database** layer directly here — real credential, real SQL, no agent in the path — because that is the layer that still holds on the day the application is the thing that failed.

:::alert{type="info" header="Complete a refund first"}
These steps replay *your* refund, so run the **Test the Refund Flow** page first. If `banking.refunds` is empty the `SELECT` feeding the `INSERT` returns no rows and you will see `INSERT 0 0` — nothing was tested.
:::

### Get a write-capable credential

**Why:** Taking Vault's authorization out of the picture on purpose. The delegation path was proved above; what is on trial now is Postgres alone.

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
CREDS_JSON=$(kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read database/creds/uc3-refund-writer -format=json")

export PG_USER=$(echo "$CREDS_JSON" | jq -r '.data.username')
export PG_PASS=$(echo "$CREDS_JSON" | jq -r '.data.password')
export RDS_HOST=$(kubectl get configmap uc3-agent-config -n banking-app -o jsonpath='{.data.DB_HOST}')

echo "$CREDS_JSON" | jq '{username: .data.username}'
```

:::alert{type="warning" header="Credential TTL: 5 minutes"}
`uc3-refund-writer` is the shortest-lived role in the workshop. If Step 3 fails with `password authentication failed`, re-run Step 1 and continue.
:::

### Positive control — the credential really can write

**Why:** If the replay fails and you never checked this, you have not proved anything: you cannot tell a working guard from a broken credential.

Before proving a write is refused, prove this credential can write at all — otherwise the rejection in Step 3 could just as easily be a missing privilege. This inserts a copy of your most recent refund with a **fresh** `request_id`, then rolls it back, so nothing is left behind (the `uc3-refund-writer` role has no `DELETE` — refund rows are audit records).

```bash
kubectl delete pod pg-replay-uc3 -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-replay-uc3 --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop -c "
    SELECT set_config('app.current_user_sub','jaime',false);
    BEGIN;
    INSERT INTO banking.refunds (account_id, transaction_id, amount, approved_by, request_id)
    SELECT account_id, transaction_id, amount, approved_by, gen_random_uuid()
      FROM banking.refunds ORDER BY created_at DESC LIMIT 1;
    ROLLBACK;"
```

Expected output — `INSERT 0 1` is the write being accepted, `ROLLBACK` is it being discarded:

```
 set_config
------------
 jaime
(1 row)

BEGIN
INSERT 0 1
ROLLBACK
pod "pg-replay-uc3" deleted
```

### The replay — same approval, second refund

**Why:** This is the test. Same terms, same `request_id`, and the database refuses.

Identical statement, one column changed: `request_id` is now carried over from the existing row instead of generated. This is precisely the replay — the same human approval, redeemed a second time.

```bash
kubectl delete pod pg-replay-uc3 -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-replay-uc3 --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop -c "
    SELECT set_config('app.current_user_sub','jaime',false);
    INSERT INTO banking.refunds (account_id, transaction_id, amount, approved_by, request_id)
    SELECT account_id, transaction_id, amount, approved_by, request_id
      FROM banking.refunds ORDER BY created_at DESC LIMIT 1;"
```

Expected output — the write is refused by name:

```
 set_config
------------
 jaime
ERROR:  duplicate key value violates unique constraint "refunds_request_id_key"
(1 row)

pod "pg-replay-uc3" deleted
pod banking-app/pg-replay-uc3 terminated (Error)
```

The `ERROR:` line arrives on stderr and the `set_config` table on stdout, so the two may interleave differently in your terminal — what matters is the constraint name. `psql` exits non-zero, so `kubectl` also reports `terminated (Error)`; that non-zero exit **is** the replay being correctly rejected.

**Why this is a genuine negative test.** Every column is copied from a row Postgres already accepted, so the values are schema-valid and the foreign keys resolve. The privilege is present — Step 2 just wrote with this exact credential. The RLS `WITH CHECK` policy is satisfied — the GUC names the account owner, the same way it did for the row that succeeded. Nothing is left that can reject this statement except `refunds_request_id_key`. And it is a *unique index*, not application code: no bug in the agent, no compromised pod, and no stolen 5-minute credential can write a second refund for an approval that has already been paid.
