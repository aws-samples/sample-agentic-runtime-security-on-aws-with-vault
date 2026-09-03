---
title: 'Verify Per-User Data Access'
weight: 63
---

## Overview

In this module you log in as Oscar and then as Jaime and confirm that each user sees only their own accounts and transactions. You then inspect the PostgreSQL Row-Level Security (RLS) policy that enforces per-user isolation at the database layer and run `verify-uc2.sh` to validate all Use Case 2 end-to-end success criteria.

## Step 1 — Log in as Oscar, inspect accounts

Open the Banking UI URL in your browser and log in as `oscar`. The Banking UI is a chat interface — ask it a banking question such as "What are my account balances?" (or "show my accounts"). You should see accounts belonging to Oscar only.

To confirm from the cluster, run a query using Vault-vended credentials with Oscar's RLS session variable set.

This block issues a fresh credential, prints the `username` / `password` so you can see what Vault gave you, and exports them (along with `RDS_HOST`) into your shell so the psql commands further down pick them up automatically — no copy-paste required:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)

CREDS_JSON=$(kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read database/creds/uc2-personal-readonly -format=json")

# Show what Vault issued (so you can confirm it's a v-root-uc2-pers-... role)
echo "$CREDS_JSON" | jq '{username: .data.username, password: .data.password}'

# Capture for Step 1.2 and Step 2 — no copy-paste needed
export PG_USER=$(echo "$CREDS_JSON" | jq -r '.data.username')
export PG_PASS=$(echo "$CREDS_JSON" | jq -r '.data.password')
export RDS_HOST=$(kubectl get configmap banking-mcp-config -n banking-app -o jsonpath='{.data.RDS_ADDRESS}')
```

:::alert{type="warning" header="Credential TTL: 15 minutes"}
The credential issued above lives for **15 minutes** (`default_ttl`). If you take longer than that before running the psql command in Step 1.2 / Step 2, you will see `psql: error: FATAL: password authentication failed`. Re-run the whole block above — `PG_USER` and `PG_PASS` get re-exported automatically.
:::

Now spawn a transient `postgres:16-alpine` pod, run the SELECT as Oscar, and let it auto-delete (no psql binary lives in any workshop pod — this is the cluster-side equivalent of the MCP server's per-request connect → SET → SELECT pattern):

```bash
kubectl delete pod pg-client-oscar -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-client-oscar --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "SET app.current_user_sub = 'oscar'; SELECT account_number, balance FROM banking.accounts;"
```

Expected output — only Oscar's rows:

```
SET
 account_number | balance
----------------+----------
 OVI-CHK-100001 |  4250.00
 OVI-SAV-100002 | 18750.50
(2 rows)

pod "pg-client-oscar" deleted
```

## Step 2 — Switch to Jaime, confirm data isolation

Open a **new Incognito / Private browser window**, go to the Banking UI URL, and sign in as `jaime` (password `WorkshopUser1!`). In the chat, ask "What are my account balances?" (or "show my accounts"). You should see Jaime's accounts only — no rows from Oscar's data.

:::alert{type="info" header="Why a second window here?"}
**Logout** fully signs you out: the Banking UI clears its session cookies and redirects to IVIA's `/pkmslogout`, which ends the WebSEAL single sign-on session too — so logging out and back in as Jaime in the *same* window gives you a clean credential prompt. We open a **separate Incognito / Private window** here only so your Oscar session stays live in the first window for a side-by-side comparison.
:::

Run the same manual query with `app.current_user_sub = 'jaime'` (you can reuse the same Vault-vended credential — RLS isolation is driven entirely by the session variable, not by the Postgres user):

```bash
kubectl delete pod pg-client-jaime -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-client-jaime --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "SET app.current_user_sub = 'jaime'; SELECT account_number, balance FROM banking.accounts;"
```

Expected output — only Jaime's rows:

```
SET
 account_number | balance
----------------+----------
 OVI-CHK-200001 |  7830.25
 OVI-SAV-200002 | 32100.00
(2 rows)

pod "pg-client-jaime" deleted
```

## Step 3 — Inspect the Row-Level Security policy

The RLS policy lives in the `pg_policy` system catalog. Reading it requires admin access (the `uc2-personal-readonly` Vault-vended role is non-superuser and cannot query `pg_policy`). The RDS master credentials are stored in AWS Secrets Manager — pull them and run a SELECT against the catalog from a transient `postgres:16-alpine` pod:

```bash
REGION=$(echo "${RDS_HOST}" | sed -E 's/.*\.([a-z0-9-]+)\.rds\.amazonaws\.com$/\1/')
SECRET_ARN=$(aws rds describe-db-instances --region "${REGION}" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
SECRET_JSON=$(aws secretsmanager get-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" --query SecretString --output text)
MASTER_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
MASTER_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')

kubectl create secret generic db-master -n banking-app \
  --from-literal=password="${MASTER_PASS}" --dry-run=client -o yaml | kubectl apply -f -

kubectl delete pod pg-client-policy -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-client-policy --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --overrides="$(jq -n --arg host "${RDS_HOST}" --arg user "${MASTER_USER}" \
    --arg sql "SELECT polname, polcmd, polroles, pg_get_expr(polqual, polrelid) AS policy_expr FROM pg_policy JOIN pg_class ON pg_class.oid = pg_policy.polrelid WHERE pg_class.relname = 'accounts';" \
    '{spec:{containers:[{name:"pg-client-policy",image:"postgres:16-alpine",env:[{name:"PGPASSWORD",valueFrom:{secretKeyRef:{name:"db-master",key:"password"}}}],command:["psql","-h",$host,"-U",$user,"-d","workshop","-c",$sql]}],restartPolicy:"Never"}}')"

kubectl delete secret db-master -n banking-app
```

Expected output:

```
    polname    | polcmd | polroles |                               policy_expr
---------------+--------+----------+--------------------------------------------------------------------------
 user_accounts | r      | {0}      | ((user_sub)::text = current_setting('app.current_user_sub'::text, true))
(1 row)

pod "pg-client-policy" deleted
```

The `policy_expr` column shows the RLS predicate (PostgreSQL has normalised the column reference to `(user_sub)::text` and the setting name to `'app.current_user_sub'::text` — same semantic). Every `SELECT` on `banking.accounts` is automatically filtered by this predicate. If `app.current_user_sub` is not set, `current_setting(..., true)` returns `NULL` and no rows are returned — a safe default. The `polroles = {0}` value is Postgres's convention in `pg_policy` for "applies to every role" — the policy is not scoped to a specific role list, so any non-superuser role that touches the table is subject to it (the master `vault_root` role bypasses RLS because it is a superuser, which is why Step 3 reads `pg_policy` successfully).

## Step 4 — Run verify-uc2.sh

Run the end-to-end verification script:

```bash
bash infrastructure/scripts/verify-uc2.sh
```

The script checks all Use Case 2 success criteria:

| Check | What It Validates |
|---|---|
| Banking UI pod Running | `kubectl get pods -n banking-app` shows `1/1 Running` for `app=banking-ui` |
| Banking Agent pod Running | `app=banking-agent` pod is Running |
| MCP Server pod Running | `app=banking-mcp-server` pod is Running |
| ServiceAccount bound | `uc2-mcp-server-sa` exists in `banking-app` namespace |
| Vault k8s role binding | `auth/kubernetes/role/uc2` bound to `uc2-mcp-server-sa` |
| Agent Registry registration | `agent-registry/registration/display-name/agent-uc2` resolves (the OBO actor) |
| Agent ceiling policy | `uc2-agent-ceiling` policy present (the OBO agent-ceiling layer) |
| OAuth alias binding | the entity alias accessor matches the `ivia` OAuth resource server profile `config_id` |
| JIT DB creds issuable | `database/creds/uc2-personal-readonly` returns username + password |
| DB read works | SELECT from `banking.accounts` with `app.current_user_sub = 'oscar'` returns ≥ 2 rows |
| ENFC-02 enforced | INSERT with JIT creds returns `ERROR: permission denied for table` |
| ENFC-03 enforced | Egress curl from MCP pod to external URL times out (NetworkPolicy blocks) |
| MCP tool contract | `tools/list` declares no `jwt` argument on any tool — identity can only arrive in the `Authorization` header |
| Agent /health | Banking Agent returns `{"status":"healthy"}` |
| IVIA JWKS reachable | JWKS endpoint returns at least one signing key |
| Active lease exists | At least one active lease for `uc2-personal-readonly` |
| OAuth discovery | IVIA OIDC Provider `/.well-known/openid-configuration` reachable via the WRP ALB |

Expected summary output — a clean deploy self-mints the OBO token, so every check PASSes (values in parentheses — `jti`, `config_id`, lease/key counts, and the `v-…` random+timestamp suffixes — vary per run):

```
  ℹ INFO Use Case 2 — OAuth Personalized Read-Only verification

  ✓ PASS Banking UI pod Running (1 pod(s) in banking-app)
  ✓ PASS Banking Agent pod Running (1 pod(s) in banking-app)
  ✓ PASS MCP Server pod Running (1 pod(s) in banking-app)
  ✓ PASS ServiceAccount uc2-mcp-server-sa exists in banking-app
  ✓ PASS Vault k8s auth role uc2 bound to uc2-mcp-server-sa
  ✓ PASS UC2 Agent Registry: registration 'agent-uc2' resolvable by display-name (OBO actor)
  ✓ PASS UC2 agent ceiling policy 'uc2-agent-ceiling' present (OBO agent-ceiling layer)
  ✓ PASS UC2 real token carries a jti claim (jti=<uuid>)
  ✓ PASS UC2 real token carries act.sub=agent-uc2 (OBO actor binding — AGENT_IDENTITY_CLAIM_UC2=act.sub)
  ✓ PASS UC2 refresh grant FAILS CLOSED at the source — agent-uc2 refresh_token grant rejected (HTTP 400; refresh_token issued at login=no)
  ✓ PASS UC2 alias accessor 'oauth-resource-server_root_<config_id>' matches oauth profile config_id — alias binding intact
  ✓ PASS UC2 OBO allow: real token (sub + act.sub=agent-uc2) authorized database/creds/uc2-personal-readonly (username=v-JWT Toke-uc2-pers-<random>-<timestamp>)
  ✓ PASS JIT DB creds issuance: username=v-root-uc2-pers-<random>-<timestamp>
  ✓ PASS DB read: SELECT from banking.accounts returned 2 row(s) for user 'oscar' (>= 2 expected)
  ✓ PASS ENFC-02: INSERT rejected by PostgreSQL (permission denied for table)
  ✓ PASS ENFC-03: NetworkPolicy egress blocked from MCP server pod (external curl timed out)
  ✓ PASS MCP tool contract: no tool accepts a jwt argument — identity can only come from the Authorization header
  ✓ PASS Agent /health endpoint: healthy
  ✓ PASS IVIA JWKS endpoint reachable (N key(s) returned) — OAuth pre-check passed
  ✓ PASS Active Vault lease exists for uc2-personal-readonly (N lease(s))
  ✓ PASS OAuth discovery: IVIA OIDC Provider reachable (issuer=https://<wrp-alb-host>)

===============================================================================
 ✓ 21 check(s) passed
===============================================================================
```

`verify-uc2.sh` self-mints a real `agent-uc2` OBO token headlessly via the **production PKCE login path** (WebSEAL authorization-code login, then the token endpoint with `client=agent-uc2`), so on a healthy cluster the `jti`, `act.sub`, refresh-fail-closed, and OBO-allow checks all PASS. If the `uc3-agent` pod is not Running or IVIA is unreachable, the self-mint fails and those four checks WARN-skip instead — set `UC2_VERIFY_TOKEN` to a browser-captured JWT to exercise them, or re-run with `--gate` to turn a skip into a hard failure.

:::expand{header="Platform Track — RLS policy SQL and session variable pattern"}

The RLS policy is created by `seed.sql` when you run `seed-banking-db.sh` after the workspace deploy:

```sql
-- Enable RLS on the accounts and transactions tables
ALTER TABLE banking.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE banking.transactions ENABLE ROW LEVEL SECURITY;

-- Policy: each user sees only their own rows
-- current_setting('app.current_user_sub', true) returns NULL if not set (safe default)
CREATE POLICY user_accounts ON banking.accounts
  FOR SELECT
  USING (user_sub = current_setting('app.current_user_sub', true));

CREATE POLICY user_transactions ON banking.transactions
  FOR SELECT
  USING (
    account_id IN (
      SELECT id FROM banking.accounts
      WHERE user_sub = current_setting('app.current_user_sub', true)
    )
  );
```

There is no permanent `uc2_personal_readonly` Postgres role. Each Vault-vended credential is its own freshly-created Postgres role with the SELECT grants applied directly to it by Vault's database secrets engine. The `creation_statements` you saw in Step 4 of the previous page are run by Vault every time `vault read database/creds/uc2-personal-readonly` is called:

```sql
-- runs once per credential issuance
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
ALTER ROLE  "{{name}}" SET search_path TO banking, public;
GRANT USAGE ON SCHEMA banking TO "{{name}}";
GRANT SELECT ON ALL TABLES IN SCHEMA banking TO "{{name}}";
ALTER DEFAULT PRIVILEGES IN SCHEMA banking GRANT SELECT ON TABLES TO "{{name}}";
```

Three consequences flow from this direct-GRANT-no-inheritance design: (1) every credential's privileges are auditable on its own role — there is no shared parent role to inspect; (2) when the credential's lease expires, Vault's `revocation_statements` drop the role and all grants disappear with it; (3) INSERT / UPDATE / DELETE were never granted, so they cannot be acquired by privilege escalation — there is no parent role to GRANT through.

How the session variable activates RLS:

```sql
-- The MCP Server runs this before every SELECT query:
SET app.current_user_sub = 'oscar';

-- PostgreSQL evaluates the RLS predicate for every row:
WHERE user_sub = current_setting('app.current_user_sub', true)
-- → WHERE user_sub = 'oscar'
```

The `true` argument to `current_setting` tells Postgres to return `NULL` rather than raise an error if the setting is not configured — this is the safe default that returns zero rows instead of all rows when the session variable is missing.

Why Vault-vended credentials activate RLS but the DBA admin account does not:
RLS policies apply to non-superuser roles. The `vault_root` connection role (used by Vault to create/revoke credentials) bypasses RLS because it is a superuser in the workshop DB. The ephemeral `uc2_personal_readonly` role is non-superuser, so RLS applies on every query.
:::

:::expand{header="Agent Developer Track — MCP server tool execution flow"}

The Banking Agent exposes a `/chat` endpoint. When a user asks "What are my account balances?", the Strands SDK routes the request to the `get_accounts` MCP tool. Here is the call chain:

```
Banking UI
  POST /chat  { message: "What are my account balances?" }
              Authorization: Bearer <access_token>   ← from the httpOnly cookie
    ↓
Banking Agent (Strands SDK)
  jwt = request.headers["Authorization"]              ← identity read from the header
  agent.invoke_with_tools("What are my account balances?")
    ↓  (tool routing)
  POST /mcp  tools/call get_accounts  { arguments: {} }
             Authorization: Bearer <access_token>     ← forwarded unchanged, still the header
    ↓
MCP Server  POST /mcp
  const jwt = req.get('Authorization')                ← the ONLY place the token is read
  handler: "get_accounts"                             ← takes no arguments at all
    ↓
  vaultClient.getDbCreds(jwt)             ← JWT as X-Vault-Token → DB creds (one call, per request)
    ↓
  pgClient.connect(host, user, password)
  await pgClient.query("SET app.current_user_sub = $1", [sub])
  await pgClient.query("SELECT * FROM banking.accounts")
    ↓
  pgClient.end()
  await revokeLease(creds.leaseId)         ← credential handed back now, not left to TTL
    ↓
  return accounts                          ← MCP tool response
    ↓
Banking Agent formats response
  → "You have 2 accounts: OVI-CHK-100001 ($4,250) and OVI-SAV-100002 ($18,750)"
```

Key design choices:

- **Per-request credential fetch**: Each `get_accounts` or `get_transactions` tool call presents the user's OAuth JWT via `X-Vault-Token` on a fresh `database/creds` read. This creates one audit log entry per tool invocation — linking user identity to data access at query granularity.
- **Connection closed after query**: The Postgres connection is opened, used, and closed within the tool handler. No connection pool is used. This ensures the JIT credential's Postgres session variable (`app.current_user_sub`) is set fresh on every connection — no risk of session state leaking between users.
- **Identity comes from the header, never from the tool arguments**: `get_accounts` declares no parameters and `get_transactions` declares only an optional `account_id`. The token the MCP server acts on is read from `Authorization: Bearer` on the request and closed over by the tool handlers (`createMcpServer(authenticatedJwt)`), so there is no field in the tool contract for a caller to put an identity in. If there were, the identity Vault saw would be whatever the caller typed into the payload and the header would constrain nothing.
- **The credential is handed back, not left to expire**: after the connection closes, the handler's `finally` block calls `revokeLease()` against `sys/leases/revoke` using the MCP server's own Kubernetes-auth Vault token. The credential exists for the duration of one query. See the [Credential Revocation](../65-credential-revocation/) page.
- **The `sub` used for RLS is decoded from the JWT, and that is safe here**: `extractSubFromJwt()` base64-decodes the payload to get `sub` for `set_config('app.current_user_sub', ...)` — it does **not** verify the signature, and the code says so. The verification that matters already happened one step earlier: Vault validated the same token against IVIA's JWKS before issuing any credential. A forged token never gets a Postgres credential at all, so a `sub` decoded from one never reaches a live connection. The decode is a convenience on a token Vault has already accepted, not an identity decision.
:::

---

### What Would Have Failed

**Without workload identity for the MCP Server (OBJ-1 failure):** If the MCP Server pod used the `default` ServiceAccount instead of `uc2-mcp-server-sa`, Vault's Kubernetes auth role binding would reject its startup token request. The MCP Server could not authenticate to Vault with its workload identity — there is no separate `auth/jwt/login` path in the native model, so the workload-identity gate cannot be sidestepped. Vault's `bound_service_account_names = ["uc2-mcp-server-sa"]` is the gating check.

**Without user JWT (OBJ-3 failure):** If the Banking Agent called the MCP Server tools without forwarding the user's JWT, the MCP Server would have no user identity to present to Vault's OAuth resource server. The design choice to make the presented user JWT (via `X-Vault-Token`) the only path to DB credentials means "no JWT" directly translates to "no DB access" — the agent cannot act on behalf of no one.

**With the JWT as a tool argument (OBJ-3 failure, the subtle one):** If `get_accounts` took a `jwt` parameter and the handler acted on it, the `Authorization` header would be decoration. Anything able to reach the MCP server — a prompt injection that talks the agent into passing a different token, a second workload on the pod network — would choose the identity Vault saw, and every downstream control (the OBO intersection, the RLS predicate, the audit record) would faithfully enforce the *attacker's* choice of user. The header would still be checked, and it would still constrain nothing. This is why the tools declare no `jwt` parameter at all: the contract has nowhere to put an identity.

**With shared DB credentials (OBJ-2 failure):** If a single long-lived Postgres password were used for all users, Row-Level Security would still filter rows (because `app.current_user_sub` would still be set), but a compromised credential would give an attacker access to all users' data by simply setting a different `app.current_user_sub` value. JIT credentials limit each credential to a 15-minute window and a specific Vault token entity — a stolen credential self-destructs and the Vault audit log records which user's OAuth JWT it was issued for.

**Without audit logging (OBJ-5 failure):** The Vault audit log entry for the `database/creds/uc2-personal-readonly` read — authorized by the presented OAuth JWT — carries the resolved requester identity and a `lease_id` that can be joined to the Postgres pgaudit log in CloudWatch. Without Vault audit logging, there is no starting point to attribute a specific SELECT query to a specific user identity — the data access event becomes unattributable.
