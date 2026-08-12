---
title: 'The Bypass Test'
weight: 73
---

## Where Enforcement Now Lives: at Vault, per request

Vault Enterprise's OAuth resource server enforces the delegation itself. When the delegated JWT is presented via `X-Vault-Token`, Vault resolves the agent actor from `act.sub`, intersects that agent's ceiling with the human's baseline, and narrows the result per request from the `vault:path_access` RAR. Two attacks with genuine, IVIA-signed tokens fail **at Vault** — before any credential is issued:

- **Wrong agent** — a real token for the same human, delegated to a *different registered* agent (`agent-uc2`), is denied the refund path. `agent-uc2`'s ceiling omits it, so the intersection is empty **even though the human's own baseline permits it**.
- **Wrong RAR path** — a token whose `vault:path_access` RAR names a path *other than* the one being requested is denied **even though the human baseline and the agent ceiling both permit the target path**. The per-request RAR is a hard, in-Vault narrowing.

## Run the Bypass Test

```bash
cd infrastructure/scripts && ./verify-uc3.sh --bypass
```

The script first mints a **real** delegated token for `oscar` (PKCE login plus an RFC 8693 token exchange), then runs its checks against it — so every denial is attributable to the one thing that was changed, and the test can never silently pass on an infrastructure error. It ends with **7 PASS and 1 WARN**; the WARN is expected and explained below.

- **Check 14 — untrusted signer:** forges an HS256 JWT whose claims are *identical* to the allowed token (same `iss`, `aud`, `sub`, `act.sub`, RAR) so that only the signature differs. Vault trusts only IVIA's RS256 JWKS, so the token dies at the signature layer.
- **Check 15 — token shape:** confirms the real delegated token carries a non-empty `jti` and `act.sub=uc3-actor`, the claims the next two checks depend on.
- **Check 16 — the positive control:** the same real token, with a RAR naming the path it is asking for, **is allowed** and vends a credential. Without this, the denials below would prove nothing — a broken deploy denies everything.
- **Check 17 — wrong RAR path (the money shot):** the same real token, presented to `database/creds/uc3-readonly`, which its RAR does not name. Denied with `RAR_NO_MATCH` even though the entity ACL and the agent ceiling both permit that path.
- **Check 18 — wrong agent:** a genuine UC2 login for the *same human* (`sub=oscar`, `act.sub=agent-uc2`) is denied `database/creds/uc3-refund-writer`. `agent-uc2`'s ceiling omits the refund path, so the intersection with oscar's baseline is empty. This is cross-use-case isolation, proven with a real token.
- **Check 19 — wrong actor (optional, skipped by default):** would present a token whose `act.sub` names an *unregistered* agent. Production IVIA will only ever sign `act.sub=uc3-actor`, so such a token cannot be minted here — it has to be supplied by an operator via `UC3_WRONG_ACTOR_TOKEN`. The check WARN-skips without it. **This is expected, not a failure:** Check 18 already proves that delegation to the wrong agent fails closed.

**Expected output** — 7 PASS and the Check 19 WARN:

```
  ℹ INFO Use Case 3 — CIBA Privileged verification — BYPASS TEST MODE

  ✓ PASS Self-mint: minted a real IVIA-issued delegated token + subject token for 'oscar'
  ✓ PASS Bypass Check 14 PASSED: Vault rejected the HS256 forgery whose claims match the ALLOWED delegated token (iss/aud/sub/act.sub/RAR identical) — only the signature differs ...
  ✓ PASS Bypass Check 15: REAL delegated token carries a jti claim (sub=oscar, jti=...)
  ✓ PASS Bypass Check 15: REAL delegated token carries act.sub=uc3-actor (OBO actor claim Vault resolves)
  ✓ PASS Bypass Check 16 PASSED: the delegated token ... was ALLOWED to read database/creds/uc3-refund-writer ...
  ✓ PASS Bypass Check 17 PASSED: the delegated token (RAR path=database/creds/uc3-refund-writer) was DENIED reading database/creds/uc3-readonly with RAR_NO_MATCH even though the entity ACL + agent ceiling permit it ...
  ✓ PASS Bypass Check 18 PASSED: the agent-uc2 UC2 token (sub=oscar, act.sub=agent-uc2) was DENIED reading database/creds/uc3-refund-writer — agent-uc2's ceiling omits the refund path ...
  ⚠ WARN Bypass Check 19: SKIPPED — no UC3_WRONG_ACTOR_TOKEN supplied ... production IVIA cannot mint a wrong-actor token (it only signs act.sub=uc3-actor), so it is operator-supplied and NOT required for green (Check 18 already proves delegation is mandatory).

===============================================================================
 ✓ 7 check(s) passed
===============================================================================
```

## Three Independent Denials, Each Sufficient On Its Own

| Layer | Mechanism | What It Enforces |
|---|---|---|
| JWT signature | JWKS validation against IVIA's RS256 public keys (resource server profile) | Only IVIA-signed tokens are accepted — HS256 self-signed tokens are always rejected |
| Agent actor | `act.sub` resolved against the Agent Registry, then that agent's ceiling intersected with the human baseline | A token delegated to a **different** registered agent is denied the refund path — `agent-uc2`'s ceiling omits it, so the intersection is empty even though the human's baseline permits it (Check 18) |
| Per-request RAR | `vault:path_access` path must match the requested path | Evaluated in Vault at the point of use: a delegated token whose RAR names a different path is denied **even though baseline ∩ ceiling permit the target** |

The RAR-path control is the one that proves enforcement moved *into* Vault: the human baseline and the agent ceiling both allow `database/creds/uc3-refund-writer`, yet Vault still denies the request when the per-request `vault:path_access` RAR does not name that exact path. Vault — not IVIA, not the agent — is the interpreter of the RAR.

### Threat Model

**What this protects against:** A rogue agent pod that obtains a user's delegated token cannot repurpose it. If the token was delegated to a different agent, that agent's ceiling does not include the refund path and the intersection with the human's baseline is empty (Check 18); if it carries a `vault:path_access` RAR for a different path, Vault narrows the token away from the refund-writer credential (Check 17). A self-forged token is rejected even earlier, at RS256 signature validation (Check 14). No DB credentials are ever issued.

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
kubectl delete pod pg-rls-test -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-rls-test --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop -c "
    SELECT set_config('app.current_user_sub','jaime',false);
    SELECT 'jaime' AS acting_as, count(*) AS tx_count FROM banking.transactions;
    SELECT set_config('app.current_user_sub','oscar',false);
    SELECT 'oscar' AS acting_as, count(*) AS tx_count FROM banking.transactions;" >/dev/null
for _ in $(seq 60); do
  case "$(kubectl get pod pg-rls-test -n banking-app -o jsonpath='{.status.phase}' 2>/dev/null)" in
    Succeeded|Failed) break ;;
  esac
  sleep 2
done
kubectl logs pg-rls-test -n banking-app
kubectl delete pod pg-rls-test -n banking-app --now >/dev/null 2>&1
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
kubectl delete pod pg-insert-uc3 -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-insert-uc3 --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "INSERT INTO banking.refunds (account_id, transaction_id, amount, approved_by, request_id)
         VALUES ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000', 1.00, 'least-priv-test', gen_random_uuid());" >/dev/null
for _ in $(seq 60); do
  case "$(kubectl get pod pg-insert-uc3 -n banking-app -o jsonpath='{.status.phase}' 2>/dev/null)" in
    Succeeded|Failed) break ;;
  esac
  sleep 2
done
kubectl logs pg-insert-uc3 -n banking-app
kubectl delete pod pg-insert-uc3 -n banking-app --now >/dev/null 2>&1
```

Expected output:

```
ERROR:  permission denied for table refunds
```

The loop waits for **either** terminal phase before reading the log. `psql` exits non-zero on a SQL error, so this pod is expected to end in `Failed` — and that non-zero exit **is** the INSERT being correctly rejected.

The Postgres GRANT layer rejects the INSERT before the RLS policy (or any constraint) is even evaluated. This confirms that a bug in the agent code that accidentally attempted a write would fail closed at the database layer — Vault's `uc3-readonly` role has no write capability.

### Section 4 — Hostile Read Attempt (Owner Predicate)

RLS is not the only layer scoping refund reads. The `check_refund_status` tool adds an explicit **owner predicate** — it `JOIN banking.accounts` and requires `a.user_sub = <authenticated_sub>` — so a `refund_id` you do not own returns the **same** empty result as a non-existent one. The agent reports `{"error": "Refund <id> not found"}` either way, leaking nothing about another user's refunds. This section proves that predicate at the database layer with the `uc3-readonly` credential from Step 2.1, running the exact query the agent runs (`uc3-agent/app/agent.py`, `check_refund_status`).

Refunds are **created by you** during the CIBA approval flow (page 71) — they are never seeded — so the IDs below are examples from one run; **yours will differ.**

#### Step 4.1 — Find a refund you created

A refund is visible only to its owner (RLS), so list refunds under each persona you ran a refund as:

```bash
kubectl delete pod pg-find-refund -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-find-refund --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop -c "
    SELECT set_config('app.current_user_sub','oscar',false);
    SELECT 'oscar' AS persona, refund_id, amount::float AS amount FROM banking.refunds;
    SELECT set_config('app.current_user_sub','jaime',false);
    SELECT 'jaime' AS persona, refund_id, amount::float AS amount FROM banking.refunds;" >/dev/null
for _ in $(seq 60); do
  case "$(kubectl get pod pg-find-refund -n banking-app -o jsonpath='{.status.phase}' 2>/dev/null)" in
    Succeeded|Failed) break ;;
  esac
  sleep 2
done
kubectl logs pg-find-refund -n banking-app
kubectl delete pod pg-find-refund -n banking-app --now >/dev/null 2>&1
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
kubectl run pg-owner-test --restart=Never --image=postgres:16-alpine -n banking-app \
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
     WHERE r.refund_id = '${REFUND_ID}' AND a.user_sub = '${OWNER}';" >/dev/null
for _ in $(seq 60); do
  case "$(kubectl get pod pg-owner-test -n banking-app -o jsonpath='{.status.phase}' 2>/dev/null)" in
    Succeeded|Failed) break ;;
  esac
  sleep 2
done
kubectl logs pg-owner-test -n banking-app
kubectl delete pod pg-owner-test -n banking-app --now >/dev/null 2>&1
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
