---
title: 'Scope Enforcement (Layer 2)'
weight: 64
---

## Overview

Use Case 2 enforces the principle of least privilege at two independent layers:

- **Vault policy (Layer 2a):** The `uc2-personal` policy grants only `database/creds/uc2-personal-readonly`. Attempts to read write-capable credential roles are rejected by Vault with a 403.
- **Postgres GRANTs (Layer 2b):** Even if the Vault policy were widened, the `uc2_personal_readonly` Postgres role has no INSERT, UPDATE, or DELETE privileges. The database rejects write operations independently of what Vault's policy says.

This defense-in-depth means that a single control being misconfigured does not open a write path. Both layers must be bypassed for a write to succeed.

## Section 1 — Vault Policy Enforcement

### Step 1.1 — Read the uc2-personal policy

```bash
kubectl exec -n vault vault-0 -- vault policy read uc2-personal
```

Expected output:

```hcl
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

Note: there is no path for any Use Case 3 write-capable role (e.g., `database/creds/uc3-refund-writer`). The policy grants `read` on exactly one database credential path.

### Step 1.2 — Attempt to read a write-capable credential role

Obtain a Vault token using the `uc2-personal` policy and attempt to read a Use Case 3 credential:

```bash
# Get a Vault token bound to uc2-personal policy
UC2_TOKEN=$(kubectl exec -n vault vault-0 -- \
  vault token create -policy=uc2-personal -ttl=5m -field=token 2>/dev/null)

# Attempt to read Use Case 3 write-capable credentials
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_TOKEN='${UC2_TOKEN}' vault read database/creds/uc3-refund-writer"
```

Expected response:

```
Error reading database/creds/uc3-refund-writer: Error making API request.

URL: GET http://vault.vault.svc.cluster.local:8200/v1/database/creds/uc3-refund-writer
Code: 403. Errors:

* 1 error occurred:
	* permission denied
```

The 403 confirms the Vault policy layer is working. The `uc2-personal` policy has no capability on `database/creds/uc3-refund-writer` — the request is rejected before it reaches the database secrets engine.

### Step 1.3 — Confirm the policy boundary in the audit log

```bash
kubectl logs -n vault vault-0 --tail=20 \
  | grep '"type":"response"' \
  | jq 'select(.response.data.error != null and (.request.path | contains("uc3")))' \
  | jq '{time: .time, path: .request.path, error: .response.data.error}'
```

Expected output:

```json
{
  "time": "2026-05-12T10:15:22.456Z",
  "path": "database/creds/uc3-refund-writer",
  "error": "1 error occurred:\n\t* permission denied\n\n"
}
```

The audit log records the denied request with the path and error — evidence that the policy layer fired.

## Section 2 — Database GRANT Enforcement

### Step 2.1 — Obtain Vault-vended uc2-personal-readonly credentials

```bash
kubectl exec -n vault vault-0 -- \
  vault read database/creds/uc2-personal-readonly -format=json \
  | jq '{username: .data.username, password: .data.password}'
```

Record the `username` and `password` values.

### Step 2.2 — Attempt INSERT with those credentials

```bash
RDS_HOST=$(kubectl get configmap uc2-mcp-config -n banking-app \
  -o jsonpath='{.data.RDS_HOST}')

kubectl exec -n banking-app deploy/banking-mcp-server -- \
  sh -c "PGPASSWORD='<password>' psql -h ${RDS_HOST} -U <username> -d workshop \
  -c \"INSERT INTO banking.accounts (user_sub, account_number, balance)
       VALUES ('attacker@example.com', 'FAKE-001', 999999.00);\""
```

Expected output:

```
ERROR:  permission denied for table accounts
```

The Postgres GRANT layer rejected the INSERT independently of Vault policy. Even if an attacker obtained a `uc2-personal-readonly` credential through a Vault misconfiguration that widened the policy scope, the database GRANT would still prevent writes.

### Step 2.3 — Confirm the GRANT configuration

Inspect the Postgres role's privileges:

```bash
kubectl exec -n banking-app deploy/banking-mcp-server -- \
  sh -c "PGPASSWORD='<admin_password>' psql -h ${RDS_HOST} -U vault_root -d workshop \
  -c \"\dp banking.accounts\""
```

Expected output (key columns):

```
 Schema  |  Name    | Type  | Access privileges
---------+----------+-------+-------------------
 banking | accounts | table | vault_root=arwdDxt/vault_root+
         |          |       | uc2_personal_readonly=r/vault_root
```

The `uc2_personal_readonly` role has `r` (SELECT) only. The `arwdDxt` privileges (insert/select/update/delete/truncate/references/trigger) belong to `vault_root` alone.

:::expand{header="Platform Track — Defense-in-depth: how Vault policy and DB GRANTs create independent enforcement layers"}

The two enforcement layers protect against different failure modes:

| Failure Scenario | Vault Policy Layer | DB GRANT Layer |
|---|---|---|
| Vault policy misconfiguration | Would fail to catch | Still blocks write |
| DB GRANT misconfiguration | Would still block via policy | Would fail to catch |
| Compromised Use Case 2 Vault token | Policy blocks Use Case 3 paths | DB blocks write ops |
| Direct DB connection (bypass Vault) | N/A — no standing credentials | DB blocks write ops for any non-admin role |

The "no standing credentials" property of OBJ-2 is what makes the last row possible: an attacker who bypasses Vault still cannot write to the database because there is no long-lived credential with write access to steal. The only credentials in existence are the ephemeral Vault-vended ones, and those have only `r` (SELECT) at the DB GRANT layer.

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
