---
title: 'Scope Enforcement (Layer 2)'
weight: 64
---

## Overview

Use Case 2 enforces the principle of least privilege at two independent layers:

- **Vault policy (Layer 2a):** The MCP server's own workload policy, `uc2-personal`, grants nothing but lease revocation. Every credential it uses is authorized by the *user's* OAuth token, not by its workload identity. Attempts to read any credential role with the workload token — write-capable or not — are rejected by Vault with a 403.
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
# UC2 MCP server workload identity — lease revocation only.
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
```

Two paths. That is the entire workload identity of the MCP server.

Read what is *missing* rather than what is there: no `database/creds/uc2-personal-readonly`, no
Use Case 3 write role, no path to any credential at all. The MCP server cannot ask Vault for a
database credential using its own identity. Every credential it uses is authorized by the
**user's** OAuth token, presented per request — which is why a request with no user attached
gets no data rather than the agent's own data.

So what is `sys/leases/revoke` for? It is the one thing the server must do as itself: hand the
credential back the moment the query finishes. Revoking a lease requires a Vault identity, and
the user's token is not the right one to use — the credential should die even if the user's
session is already gone. That single grant is the whole reason this policy still exists, and
the [Credential Revocation](../65-credential-revocation/) page watches it happen.

This is distinct from `uc2-human-baseline`, the per-user policy Vault intersects with the agent
ceiling on the on-behalf-of path shown on the previous pages. Neither carries a Use Case 3 write
path — which is what the next step proves.

### Step 1.2 — Attempt to read a write-capable credential role

Obtain a Vault token carrying the `uc2-personal` policy — the same policy the MCP server's
ServiceAccount receives — and attempt to read a Use Case 3 credential with it:

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
kubectl logs -n vault -l app.kubernetes.io/name=vault --since=10m --tail=-1 \
  | grep '"type":"response"' \
  | jq 'select(.response.data.error != null and (.request.path | contains("uc3")))' \
  | jq '{time: .time, path: .request.path, error: .response.data.error}'
```

(The label selector reads all three Vault nodes: only the node that served the denied request
logged it, so naming a single pod returns nothing whenever another node took the call. `--tail=-1`
is required alongside `-l` — with a selector `kubectl logs` otherwise returns just 10 lines per pod.
`--since=10m` rather than `--tail=N` because on a live cluster the agents are continuously calling `auth/token/lookup-self` and similar heartbeat paths, so a small `--tail` window will scroll the deny out of view within seconds. Bounding by time keeps the command deterministic from the attendee's perspective.)

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

kubectl create secret generic db-master -n banking-app \
  --from-literal=password="${MASTER_PASS}" --dry-run=client -o yaml | kubectl apply -f -

kubectl delete pod pg-grants -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-grants --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --overrides="$(jq -n --arg host "${RDS_HOST}" --arg user "${MASTER_USER}" \
    --arg sql "\dp banking.accounts" \
    '{spec:{containers:[{name:"pg-grants",image:"postgres:16-alpine",env:[{name:"PGPASSWORD",valueFrom:{secretKeyRef:{name:"db-master",key:"password"}}}],command:["psql","-h",$host,"-U",$user,"-d","workshop","-c",$sql]}],restartPolicy:"Never"}}')"

kubectl delete secret db-master -n banking-app
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
- **Each `"v-…"=r/vault_root` row** is a live Vault-vended ephemeral role. The `=r/` means *only the `r` (SELECT) privilege is granted* — no `a` for insert, no `w` for update, no `d` for delete. That's why your Step 2.2 INSERT got rejected. This is also the direct evidence of JIT identity at the DB layer: every active credential is visible as its own row, and the list shrinks as roles are dropped — immediately when the MCP server revokes the lease at the end of a query, or at lease expiry for the credentials you issued by hand with the root token on these pages, which nothing revokes for you.
- **`Policies` column** — the RLS predicate from the previous page. The `(u)` USING clause is the SELECT filter; `(r)` indicates it applies to `SELECT` (read).

## Section 3 — What a Stolen Token Gets You

Sections 1 and 2 showed what the token **cannot** reach. This one shows what it *can* — including when it is presented by someone who is not you. Every claim a workshop makes about token security is worth less than the five minutes it takes to check, so check this one.

### Step 3.1 — Get your own access token

The Banking UI keeps the token in an `httpOnly` cookie, which JavaScript cannot read but DevTools can show you.

In the browser tab where you are signed in as Oscar: open DevTools (**F12**), go to **Application** → **Storage** → **Cookies**, select the banking site, and copy the value of the **`access_token`** cookie. Then put it in a shell variable:

```bash
read -r -s ACCESS_TOKEN   # paste the cookie value, press Enter (input is hidden)
export ACCESS_TOKEN
echo "token length: ${#ACCESS_TOKEN}"
```

A Use Case 2 access token is roughly 800 characters. If you got something much shorter you copied the wrong cookie — `id_token` and `pkce` also live there.

### Step 3.2 — Present it to Vault twice

This is the exact call the MCP server makes: the token *is* the Vault token. Run it twice.

```bash
for attempt in 1 2; do
  kubectl delete pod vault-replay -n banking-app --ignore-not-found --now >/dev/null 2>&1
  kubectl run vault-replay --rm -i --quiet --restart=Never --image=curlimages/curl:8.11.1 -n banking-app \
    --command -- curl -s -H "X-Vault-Token: ${ACCESS_TOKEN}" \
      http://vault.vault.svc.cluster.local:8200/v1/database/creds/uc2-personal-readonly \
    | sed -e "s/.*\"username\":\"\([^\"]*\)\".*/attempt ${attempt} username=\1/"
done
```

Expected output — **both** succeed, with two different credentials:

```
attempt 1 username=v-JWT Toke-uc2-pers-DiVXIMGjGIeX0uV8sFm9-1788385620
attempt 2 username=v-JWT Toke-uc2-pers-gFzxJVMgIqTvaHP3K9R9-1788385654
```

### What this means, stated plainly

**Vault has no replay cache.** The delegated token is a bearer credential: whoever holds it can present it as many times as they like until it expires, and each presentation issues a fresh database credential. Nothing about the OAuth resource server model changes that, and the workshop is not going to pretend otherwise.

What limits the damage is everything *around* the token, and you have already proved each piece:

- **The credential is read-only.** Section 2's INSERT was rejected by a Postgres `GRANT`, and a replayed token gets exactly the same read-only credential.
- **It only sees one user's rows.** Row-level security scopes every result to the `sub` in the token, so a stolen token is a window onto that user's data and no one else's — you proved this on the [Verify User Access](../63-verify-user-access/) page.
- **The audience is pinned.** The token names `agent-uc2` as its audience; Vault's resource server profile rejects a token minted for a different audience.
- **The agent ceiling still applies.** Section 1 showed the same token being refused the Use Case 3 write path. Replaying it does not widen it.
- **For Use Case 3, the path is pinned per request.** The mandatory `vault:path_access` RAR narrows each delegated token to one path — the [Bypass Test](../73-bypass-test/) proves a token whose RAR names a different path is denied.
- **And a replayed Use Case 3 token still cannot pay a refund twice.** It could obtain the writer credential again, but the unique index on `banking.refunds (request_id)` refuses the second write — proved under "One Approval Pays Once".

**The honest gap:** the token's own lifetime. Check it yourself:

```bash
python3 -c "
import base64, json, os, time
p = os.environ['ACCESS_TOKEN'].split('.')[1]; p += '=' * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print('lifetime:', (c['exp'] - c['iat']) // 60, 'minutes')
print('expires in:', int((c['exp'] - time.time()) // 60), 'minutes')
"
```

Expected output on this deployment — `lifetime` is fixed by the IVIA client configuration; `expires in` counts down from whenever you signed in:

```
lifetime: 120 minutes
expires in: 79 minutes
```

Two hours is a long replay window for a bearer token, and it is set by the IVIA client configuration, not by Vault. Shortening it — and pairing it with the credential revocation you saw on the next page, which closes the *credential's* window in milliseconds — is the lever a production deployment pulls. That is the difference between a control the system enforces and a parameter someone chose; both are worth knowing which is which.

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
    // The credential existed for exactly this query. Hand it back now.
    await revokeLease(creds.leaseId);
  }
}
```

The MCP Server catches the `permission denied for table` Postgres error and returns a structured error response to the agent. The agent surfaces this to the user as "Operation not permitted" — a clean user experience that reflects the enforcement reality without exposing internal details.

The audit trail for this event: Vault audit log records the `database/creds/uc2-personal-readonly` issuance (with the user's `sub`), and Postgres pgaudit logs record the failed INSERT with the ephemeral username. Both logs are streamed to CloudWatch — Phase 6 Athena queries correlate them.
:::
