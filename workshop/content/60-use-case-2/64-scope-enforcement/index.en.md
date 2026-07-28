---
title: 'Scope Enforcement (Layer 2)'
weight: 64
---

## Overview

Use Case 2 enforces the principle of least privilege at two independent layers:

- **Vault policy (Layer 2a):** The `uc2-personal` policy grants only `database/creds/uc2-personal-readonly`. Attempts to read write-capable credential roles are rejected by Vault with a 403.
- **Postgres GRANTs (Layer 2b):** Each Vault-vended ephemeral Postgres role is created with `GRANT SELECT` only — no INSERT, UPDATE, or DELETE is ever granted (these capabilities are not in the `creation_statements` Vault runs at issuance time). Because there is no shared permanent role behind the ephemeral roles, an attacker has no parent role to GRANT through either: every credential is a fresh role with the same SELECT-only ceiling.

This defense-in-depth means that a single control being misconfigured does not open a write path. Both layers must be bypassed for a write to succeed.

## Section 1 — Vault Policy Enforcement

### Step 1.1 — Read the uc2-personal policy

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault policy read uc2-personal"
```

Expected output:

```hcl
# UC2: Personal-data agent policy (ENFC-02)
# Allows: kubernetes auth + OAuth resource server (X-Vault-Token), database creds (R/O), AWS (Bedrock) STS creds
# database/creds/uc2-personal-readonly only — no write DB roles accessible
path "database/creds/uc2-personal-readonly" {
  capabilities = ["read"]
}
path "aws/sts/bedrock-reader" {
  capabilities = ["read", "update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "sys/leases/renew" {
  capabilities = ["update"]
}
```

Note: there is no path for any Use Case 3 write-capable role (e.g., `database/creds/uc3-refund-writer`). The policy grants `read` on exactly **one** database credential path — `uc2-personal-readonly`. The other three paths give the agent its Vault-vended Bedrock STS credentials (`aws/sts/bedrock-reader`), let it inspect its own Vault token (`auth/token/lookup-self`), and let it extend an in-flight DB credential lease (`sys/leases/renew`). None of these grant write access to banking data.

### Step 1.2 — Attempt to read a write-capable credential role

Obtain a Vault token using the `uc2-personal` policy and attempt to read a Use Case 3 credential:

```bash
# Get a Vault token bound to uc2-personal policy (creating a token requires the root token)
UC2_TOKEN=$(kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault token create -policy=uc2-personal -ttl=5m -field=token" 2>/dev/null)

# Attempt to read Use Case 3 write-capable credentials
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_TOKEN='${UC2_TOKEN}' vault read database/creds/uc3-refund-writer"
```

Expected response (the `kubectl exec` will exit with code 2 — that is normal: the `vault` CLI exits non-zero on permission-denied):

```
Error reading database/creds/uc3-refund-writer: Error making API request.

URL: GET http://127.0.0.1:8200/v1/database/creds/uc3-refund-writer
Code: 403. Errors:

* 1 error occurred:
	* permission denied
```

The 403 confirms the Vault policy layer is working. The `uc2-personal` policy has no capability on `database/creds/uc3-refund-writer` — the request is rejected before it reaches the database secrets engine.

The URL field shows `http://127.0.0.1:8200` (rather than the cluster-DNS address `vault.vault.svc.cluster.local:8200`) because the `vault` CLI is running **inside** the `vault-0` pod via `kubectl exec`. In-pod, `VAULT_ADDR` defaults to the loopback. When the MCP server or another pod calls Vault from outside, it uses the cluster-DNS form — but the 403 happens at the same authorization boundary regardless of which path you arrive on.

### Step 1.3 — Confirm the policy boundary in the audit log

The audit log streams every Vault request and response. Filter the last 10 minutes for any denied response targeting a `uc3` path:

```bash
kubectl logs -n vault vault-0 --since=10m \
  | grep '"type":"response"' \
  | jq 'select(.response.data.error != null and (.request.path | contains("uc3")))' \
  | jq '{time: .time, path: .request.path, error: .response.data.error}'
```

(`--since=10m` rather than `--tail=N` because on a live cluster the agents are continuously calling `auth/token/lookup-self` and similar heartbeat paths, so a small `--tail` window will scroll the deny out of view within seconds. Bounding by time keeps the command deterministic from the attendee's perspective.)

Expected output:

```json
{
  "time": "2026-05-28T17:53:46.628779649Z",
  "path": "database/creds/uc3-refund-writer",
  "error": "hmac-sha256:6b8c1f71603b1ba3b5dc02ded1c4a2be38b5fcb07873841550ef0e32ec26e99d"
}
```

The audit log records the denied request — the `time` is when Vault rejected your call and the `path` is exactly the credential role the `uc2-personal` policy did not authorise.

The `error` field is **HMAC-hashed** by Vault's audit device, not the human-readable `"permission denied"` string. This is intentional: Vault hashes string fields in audit records so that secrets accidentally surfaced inside an error never land in plaintext on disk or in a log aggregator. The hash is deterministic per audit-device salt, so:

- you can still **correlate** repeated occurrences of the same error across audit lines (identical hashes = identical strings),
- but you cannot **read** the underlying string from the audit log directly.

To verify what the hash represents, the operator hashes the candidate string with the audit device's HMAC accessor (`vault audit hash sys/audit/file 'permission denied'` returns the same `hmac-sha256:…` value when the hashes match). For the workshop, you saw the plaintext `permission denied` from Vault's HTTP response in Step 1.2 — the audit log is the corresponding evidence-of-record that the rejection actually happened.

## Section 2 — Database GRANT Enforcement

### Step 2.1 — Obtain Vault-vended uc2-personal-readonly credentials

This block issues a fresh credential, prints the `username` / `password` so you can see what Vault gave you, and exports them into `PG_USER` and `PG_PASS` so Step 2.2 picks them up automatically — no copy-paste required:

```bash
CREDS_JSON=$(kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read database/creds/uc2-personal-readonly -format=json")

# Show what Vault issued (so you can confirm it's a v-root-uc2-pers-... role)
echo "$CREDS_JSON" | jq '{username: .data.username, password: .data.password}'

# Capture for Step 2.2 — no copy-paste needed
export PG_USER=$(echo "$CREDS_JSON" | jq -r '.data.username')
export PG_PASS=$(echo "$CREDS_JSON" | jq -r '.data.password')
export RDS_HOST=$(kubectl get configmap banking-mcp-config -n banking-app -o jsonpath='{.data.RDS_ADDRESS}')
```

:::alert{type="warning" header="Credential TTL: 15 minutes"}
The credential issued above lives for **15 minutes** (`default_ttl`). If you take longer than that before running Step 2.2's `psql` command, you will see `psql: error: FATAL: password authentication failed`. Re-run the whole Step 2.1 block to mint a fresh credential — `PG_USER` and `PG_PASS` get re-exported automatically.
:::

### Step 2.2 — Attempt INSERT with those credentials

No workshop pod has the `psql` binary pre-installed, so spawn a transient `postgres:16-alpine` pod that connects to RDS as the Vault-vended ephemeral role, attempts the INSERT, and auto-deletes when it exits. The `${PG_USER}`, `${PG_PASS}`, and `${RDS_HOST}` references resolve from the exports you just ran in Step 2.1:

```bash
kubectl delete pod pg-insert-attempt -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-insert-attempt --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${PG_USER}" -d workshop \
    -c "INSERT INTO banking.accounts (user_sub, account_number, balance)
         VALUES ('attacker@example.com', 'FAKE-001', 999999.00);"
```

Expected output (the pod exits with code 1 because `psql` returns non-zero on SQL errors — that is the *success* signal here, the INSERT was rejected):

```
ERROR:  permission denied for table accounts
pod "pg-insert-attempt" deleted
pod banking-app/pg-insert-attempt terminated (Error)
```

The Postgres GRANT layer rejected the INSERT independently of Vault policy. Even if an attacker obtained a `uc2-personal-readonly` credential through a Vault misconfiguration that widened the policy scope, the database GRANT would still prevent writes — and because every Vault-vended credential is its own freshly-created Postgres role (with grants applied directly to it), there is no permanent role to GRANT INSERT onto either.

### Step 2.3 — Confirm the GRANT configuration

The grant snapshot lives in the Postgres system catalog `pg_class.relacl`; `\dp banking.accounts` is `psql`'s pretty-printer for it. Reading it requires admin access (the ephemeral `uc2-personal-readonly` role cannot read `pg_class`), so pull the RDS master credentials from AWS Secrets Manager and run a transient `postgres:16-alpine` pod as the master:

```bash
RDS_HOST=$(kubectl get configmap banking-mcp-config -n banking-app -o jsonpath='{.data.RDS_ADDRESS}')
REGION=$(echo "${RDS_HOST}" | sed -E 's/.*\.([a-z0-9-]+)\.rds\.amazonaws\.com$/\1/')
SECRET_ARN=$(aws rds describe-db-instances --region "${REGION}" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
SECRET_JSON=$(aws secretsmanager get-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" --query SecretString --output text)
MASTER_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
MASTER_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')

kubectl delete pod pg-grants -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-grants --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${MASTER_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${MASTER_USER}" -d workshop \
    -c "\dp banking.accounts"
```

Expected output — one `vault_root=arwdDxtm/vault_root` line followed by one row per **currently-active** Vault-vended credential (every active lease maps to one Postgres role, each granted `=r/vault_root`). The exact number of `v-…` rows depends on how many leases are still live — every issuance you made on pages 62 and 63 contributes one:

```
                                                                                          Access privileges
 Schema  |   Name   | Type  |                         Access privileges                          | Column privileges |                                    Policies
---------+----------+-------+--------------------------------------------------------------------+-------------------+---------------------------------------------------------------------------------
 banking | accounts | table | vault_root=arwdDxtm/vault_root                                    +|                   | user_accounts (r):                                                             +
         |          |       | "v-root-uc2-pers-<random>-<timestamp>"=r/vault_root               +|                   |   (u): ((user_sub)::text = current_setting('app.current_user_sub'::text, true))
         |          |       | "v-root-uc2-pers-<random>-<timestamp>"=r/vault_root               +|                   |
         |          |       | "v-root-uc2-pers-<random>-<timestamp>"=r/vault_root                |                   |
(1 row)

pod "pg-grants" deleted
```

What to read from this output:

- **`vault_root=arwdDxtm/vault_root`** — the master role holds the full `arwdDxtm` privilege set on this table: **a** insert, **r** select, **w** update, **d** delete, **D** truncate, **x** references, **t** trigger, **m** maintain (Postgres 17 added `m`). The trailing `/vault_root` means *granted by* `vault_root`.
- **Each `"v-…"=r/vault_root` row** is a live Vault-vended ephemeral role. The `=r/` means *only the `r` (SELECT) privilege is granted* — no `a` for insert, no `w` for update, no `d` for delete. That's why your Step 2.2 INSERT got rejected. This is also the direct evidence of JIT identity at the DB layer: every active credential is visible as its own row, and the list shrinks as leases expire and Vault's `revocation_statements` drop the roles.
- **`Policies` column** — the RLS predicate from the previous page. The `(u)` USING clause is the SELECT filter; `(r)` indicates it applies to `SELECT` (read).

:::expand{header="Platform Track — Defense-in-depth: how Vault policy and DB GRANTs create independent enforcement layers"}

The two enforcement layers protect against different failure modes:

| Failure Scenario | Vault Policy Layer | DB GRANT Layer |
|---|---|---|
| Vault policy misconfiguration | Would fail to catch | Still blocks write |
| DB GRANT misconfiguration | Would still block via policy | Would fail to catch |
| Compromised Use Case 2 Vault token | Policy blocks Use Case 3 paths | DB blocks write ops |
| Direct DB connection (bypass Vault) | N/A — no standing credentials | DB blocks write ops for any non-admin role |

The "no standing credentials" property of OBJ-2 is what makes the last row possible: an attacker who bypasses Vault still cannot write to the database because there is no long-lived credential with write access to steal. The only credentials in existence are the ephemeral Vault-vended ones, and each of them is its own freshly-created Postgres role with only `r` (SELECT) directly granted at the DB GRANT layer — there is no permanent role to inherit additional privileges from.

This is the practical meaning of defense-in-depth: each layer is independently sufficient to block the attack. An attacker must simultaneously bypass the Vault policy layer AND obtain a PostgreSQL admin credential (which is protected by Secrets Manager and rotated by Vault) to achieve a write.
:::

:::expand{header="Agent Developer Track — How the MCP server handles INSERT errors"}

When the Banking Agent routes a user request to a tool that attempts a write operation (which should not happen in Use Case 2's read-only design, but can be triggered in testing), the MCP Server receives a Postgres error and propagates it back to the agent:

```typescript
// tools/banking-tools.ts
async function writeAccount(params: { user_sub: string; amount: number }) {
  const { username, password } = await vaultClient.getDbCredsForUser(context.jwt);
  const client = new pg.Client({ host: RDS_HOST, user: username, password, database: 'workshop' });
  await client.connect();
  try {
    await client.query('SET app.current_user_sub = $1', [context.sub]);
    await client.query(
      'INSERT INTO banking.accounts (user_sub, account_number, balance) VALUES ($1, $2, $3)',
      [params.user_sub, 'TEST-001', params.amount],
    );
  } catch (err: unknown) {
    if (err instanceof Error && err.message.includes('permission denied')) {
      return {
        error: 'Operation not permitted: this account has read-only access to banking data.',
        details: err.message,
      };
    }
    throw err;
  } finally {
    await client.end();
  }
}
```

The MCP Server catches the `permission denied for table` Postgres error and returns a structured error response to the agent. The agent surfaces this to the user as "Operation not permitted" — a clean user experience that reflects the enforcement reality without exposing internal details.

The audit trail for this event: Vault audit log records the `database/creds/uc2-personal-readonly` issuance (with the user's `sub`), and Postgres pgaudit logs record the failed INSERT with the ephemeral username. Both logs are streamed to CloudWatch — Phase 6 Athena queries correlate them.
:::
