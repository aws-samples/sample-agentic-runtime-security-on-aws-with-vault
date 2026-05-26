---
title: 'Verify Per-User Data Access'
weight: 63
---

## Overview

In this module you log in as Oscar and then as Jaime and confirm that each user sees only their own accounts and transactions. You then inspect the PostgreSQL Row-Level Security (RLS) policy that enforces per-user isolation at the database layer and run `verify-uc2.sh` to validate all Use Case 2 end-to-end success criteria.

## Step 1 — Log in as Oscar, inspect accounts

Open the Banking UI URL in your browser and log in as `oscar`. Navigate to the **Accounts** page. You should see accounts belonging to Oscar only.

To confirm from the cluster, exec into the MCP Server pod and run a query using the Vault-vended credentials for Oscar's session:

```bash
# Get a Vault-vended credential manually (root token required)
kubectl exec -n vault vault-0 -- vault read database/creds/uc2-personal-readonly
```

Note the `username` and `password`. Then:

```bash
# Get the RDS host from the MCP server ConfigMap
RDS_HOST=$(kubectl get configmap banking-mcp-config -n banking-app \
  -o jsonpath='{.data.RDS_ADDRESS}')

# Exec into the MCP Server pod and run a select
kubectl exec -n banking-app deploy/banking-mcp-server -- \
  sh -c "PGPASSWORD='<password>' psql -h ${RDS_HOST} -U <username> -d workshop \
  -c \"SET app.current_user_sub = 'oscar'; SELECT account_number, balance FROM banking.accounts;\""
```

Expected output — only Oscar's rows:

```
 account_number |  balance
----------------+-----------
 OVI-CHK-100001 | 4250.00
 OVI-SAV-100002 | 18750.50
(2 rows)
```

## Step 2 — Switch to Jaime, confirm data isolation

Log out and log in as `jaime`. Navigate to the **Accounts** page. You should see Jaime's accounts only — no rows from Oscar's data.

Run the same manual query with `app.current_user_sub = 'jaime'`:

```bash
kubectl exec -n banking-app deploy/banking-mcp-server -- \
  sh -c "PGPASSWORD='<password>' psql -h ${RDS_HOST} -U <username> -d workshop \
  -c \"SET app.current_user_sub = 'jaime'; SELECT account_number, balance FROM banking.accounts;\""
```

Expected output — only Jaime's rows:

```
 account_number |  balance
----------------+-----------
 OVI-CHK-200001 |  7830.25
 OVI-SAV-200002 | 32100.00
(2 rows)
```

## Step 3 — Inspect the Row-Level Security policy

Connect to RDS as the `vault_root` user (or another admin user) and inspect the RLS policy:

```bash
kubectl exec -n vault vault-0 -- \
  vault read database/creds/uc2-personal-readonly -format=json | jq -r '.data'
```

Then on RDS:

```bash
kubectl exec -n banking-app deploy/banking-mcp-server -- \
  sh -c "PGPASSWORD='<admin_password>' psql -h ${RDS_HOST} -U vault_root -d workshop \
  -c 'SELECT polname, polcmd, polroles, pg_get_expr(polqual, polrelid) AS policy_expr
      FROM pg_policy
      JOIN pg_class ON pg_class.oid = pg_policy.polrelid
      WHERE pg_class.relname = '\''accounts'\'';'"
```

Expected output:

```
    polname      | polcmd | polroles |              policy_expr
-----------------+--------+----------+-----------------------------------------
 user_accounts   | r      | {}       | (user_sub = current_setting('app.current_user_sub', true))
(1 row)
```

The `policy_expr` column shows the RLS predicate: `user_sub = current_setting('app.current_user_sub', true)`. Every `SELECT` on `banking.accounts` is automatically filtered by this predicate. If `app.current_user_sub` is not set, `current_setting(..., true)` returns `NULL` and no rows are returned — a safe default.

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
| Vault jwt role | `auth/jwt/role/uc2-jwt` exists with `bound_audiences=[agent-uc2]` |
| JIT DB creds issuable | `database/creds/uc2-personal-readonly` returns username + password |
| DB read works | SELECT from `banking.accounts` returns rows with JIT creds |
| ENFC-02 enforced | INSERT with JIT creds returns `ERROR: permission denied for table` |
| ENFC-03 enforced | Egress curl from MCP pod to external URL times out (NetworkPolicy blocks) |
| Agent /health | Banking Agent returns `{"status":"healthy"}` |
| IVIA JWKS reachable | JWKS endpoint returns at least one signing key |
| Active lease exists | At least one active lease for `uc2-personal-readonly` (with VAULT_ROOT_TOKEN) |

Expected summary output:

```
[PASS] Banking UI pod Running (1 pod(s) in banking-app)
[PASS] Banking Agent pod Running (1 pod(s) in banking-app)
[PASS] MCP Server pod Running (1 pod(s) in banking-app)
[PASS] ServiceAccount uc2-mcp-server-sa exists in banking-app
[PASS] Vault k8s auth role uc2 bound to uc2-mcp-server-sa
[PASS] Vault jwt auth role uc2-jwt exists (bound_audiences contains agent-uc2)
[PASS] JIT DB creds issuance: username=v-jwt-uc2-personal-readonly-AbCd1234
[PASS] DB read: SELECT from banking.accounts returned 2 row(s)
[PASS] ENFC-02: INSERT rejected by PostgreSQL (permission denied for table)
[PASS] ENFC-03: NetworkPolicy egress blocked from MCP server pod
[PASS] Agent /health endpoint: healthy
[PASS] IVIA JWKS endpoint reachable (2 key(s) returned)
[PASS] Active Vault lease exists for uc2-personal-readonly (1 lease(s))
[PASS] OAuth discovery: IVIA /.well-known/openid-configuration returns valid JSON

14 check(s) passed, 0 failed.
```

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

The `uc2_personal_readonly` permanent Postgres role is the grant vehicle. The ephemeral Vault-vended credentials are created `IN ROLE uc2_personal_readonly`, inheriting SELECT but not INSERT/UPDATE/DELETE.

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
  POST /api/chat  { message: "What are my account balances?", jwt: "<user_jwt>" }
    ↓
Banking Agent (Strands SDK)
  agent.invoke_with_tools("What are my account balances?")
    ↓  (tool routing)
  MCPClient.call_tool("get_accounts", { jwt: "<user_jwt>" })
    ↓
MCP Server  POST /mcp
  handler: "get_accounts"
    ↓
  vaultClient.getDbCredsForUser(jwt)      ← jwt auth login + DB creds (per request)
    ↓
  pgClient.connect(host, user, password)
  await pgClient.query("SET app.current_user_sub = $1", [sub])
  await pgClient.query("SELECT * FROM banking.accounts")
    ↓
  pgClient.end()                           ← connection closed; creds start TTL countdown
    ↓
  return accounts                          ← MCP tool response
    ↓
Banking Agent formats response
  → "You have 2 accounts: OVI-CHK-100001 ($4,250) and OVI-SAV-100002 ($18,750)"
```

Key design choices:

- **Per-request Vault login**: Each `get_accounts` or `get_transactions` tool call performs a fresh `jwt/login`. This creates one audit log entry per tool invocation — linking user identity to data access at query granularity.
- **Connection closed after query**: The Postgres connection is opened, used, and closed within the tool handler. No connection pool is used. This ensures the JIT credential's Postgres session variable (`app.current_user_sub`) is set fresh on every connection — no risk of session state leaking between users.
- **JWT never stored**: The MCP Server extracts the `sub` from the Vault `token_meta` response — it never decodes the JWT itself. Vault is the authority on what the JWT says.
:::

---

### What Would Have Failed

**Without workload identity for the MCP Server (OBJ-1 failure):** If the MCP Server pod used the `default` ServiceAccount instead of `uc2-mcp-server-sa`, Vault's Kubernetes auth role binding would reject its startup token request. The MCP Server could not authenticate to Vault with its workload identity, and the fallback jwt auth login path would be the only auth option — creating a situation where the workload identity layer is bypassed entirely. Vault's `bound_service_account_names = ["uc2-mcp-server-sa"]` is the gating check.

**Without user JWT (OBJ-3 failure):** If the Banking Agent called the MCP Server tools without forwarding the user's JWT, the MCP Server would have no user identity to present to Vault's jwt auth. The design choice to make the Vault jwt auth the only path to DB credentials means "no JWT" directly translates to "no DB access" — the agent cannot act on behalf of no one.

**With shared DB credentials (OBJ-2 failure):** If a single long-lived Postgres password were used for all users, Row-Level Security would still filter rows (because `app.current_user_sub` would still be set), but a compromised credential would give an attacker access to all users' data by simply setting a different `app.current_user_sub` value. JIT credentials limit each credential to a 15-minute window and a specific Vault token entity — a stolen credential self-destructs and the Vault audit log records which user's jwt login it was issued for.

**Without audit logging (OBJ-5 failure):** The Vault audit log entry for `auth/jwt/login` carries `token_meta.sub = "oscar"`. The subsequent `database/creds/uc2-personal-readonly` entry carries the same `lease_id` that can be joined to the Postgres pgaudit log in CloudWatch. Without Vault audit logging, there is no starting point to attribute a specific SELECT query to a specific user identity — the data access event becomes unattributable.
