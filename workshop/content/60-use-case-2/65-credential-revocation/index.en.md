---
title: 'Credential Revocation'
weight: 65
---

## Overview

In this module you observe the full credential lifecycle for a Use Case 2 session: a Postgres credential is issued, used to confirm its existence, then explicitly revoked, and you verify three things in succession — (a) the Postgres role is gone, (b) Vault's active-leases list no longer contains your lease, (c) both the issuance and the revocation appear in the audit log keyed by `lease_id`.

**The production code path** is `POST /v1/sys/leases/revoke` against Vault, and the MCP server calls it itself: every credential it obtains is revoked as soon as the query it was issued for returns, using its own Kubernetes-auth Vault token rather than the caller's. In this page you issue a credential by hand and exercise the same API directly via the `vault lease revoke` CLI — identical mechanism, no UI dependency, immediate evidence.

Load the Vault root token once at the start of the page — several admin-only paths (`database/creds/...`, `sys/leases/...`) are unreachable from the `uc2-personal` policy and require the root token for inspection:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
```

## Step 1 — Issue a fresh credential and capture the lease_id

This block reads a credential, prints the `lease_id` and Postgres `username`, and exports them into your shell so subsequent steps pick them up automatically — no copy-paste required:

```bash
CREDS_JSON=$(kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read database/creds/uc2-personal-readonly -format=json")

export LEASE_ID=$(echo "$CREDS_JSON" | jq -r .lease_id)
export PG_USER=$(echo "$CREDS_JSON" | jq -r .data.username)

echo "LEASE_ID=$LEASE_ID"
echo "PG_USER=$PG_USER"
```

Expected output:

```
LEASE_ID=database/creds/uc2-personal-readonly/7oGTYoP3ASqa87UbpFGlylEp
PG_USER=v-root-uc2-pers-IwaMUs8kxzRLvjsvSjwO-1780000048
```

You now hold the credential's full `lease_id` and the ephemeral Postgres role name. Keep this shell session for the rest of the page — the exports are how `LEASE_ID` and `PG_USER` flow into later commands.

## Step 2 — Confirm the Postgres role exists

The Vault dynamic secrets engine just created `${PG_USER}` as a real Postgres role. Pull the RDS master credentials from AWS Secrets Manager and run a transient `postgres:16-alpine` pod to confirm:

```bash
RDS_HOST=$(kubectl get configmap banking-mcp-config -n banking-app -o jsonpath='{.data.RDS_ADDRESS}')
REGION=$(echo "${RDS_HOST}" | sed -E 's/.*\.([a-z0-9-]+)\.rds\.amazonaws\.com$/\1/')
SECRET_ARN=$(aws rds describe-db-instances --region "${REGION}" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
SECRET_JSON=$(aws secretsmanager get-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" --query SecretString --output text)
MASTER_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
MASTER_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')

kubectl delete pod pg-role-before -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-role-before --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${MASTER_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${MASTER_USER}" -d workshop \
    -c "SELECT rolname FROM pg_roles WHERE rolname='${PG_USER}';"
```

Expected output — exactly one row, your fresh ephemeral role:

```
                     rolname
-------------------------------------------------
 v-root-uc2-pers-IwaMUs8kxzRLvjsvSjwO-1780000048
(1 row)

pod "pg-role-before" deleted
```

## Step 3 — Revoke the lease (the production code path)

Call the same Vault API a production session-end handler would call:

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault lease revoke '${LEASE_ID}'"
```

Expected output:

```
All revocation operations queued successfully!
```

Vault has queued the revocation. Internally Vault now runs the `revocation_statements` configured on the `uc2-personal-readonly` role against Postgres — the symmetric `REVOKE`s that undo every `GRANT` from the role's `creation_statements`, followed by `DROP ROLE IF EXISTS`. This happens within milliseconds.

## Step 4 — Confirm the Postgres role is gone

Re-run the role check. The lease's ephemeral Postgres role should be gone:

```bash
kubectl delete pod pg-role-after -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run pg-role-after --rm -i --restart=Never --image=postgres:16-alpine -n banking-app \
  --env="PGPASSWORD=${MASTER_PASS}" \
  --command -- psql -h "${RDS_HOST}" -U "${MASTER_USER}" -d workshop \
    -c "SELECT rolname FROM pg_roles WHERE rolname='${PG_USER}';"
```

Expected output:

```
 rolname
---------
(0 rows)

pod "pg-role-after" deleted
```

Zero rows. The ephemeral role has been dropped. Any open Postgres connection that was using this credential is now broken at its next query — `password authentication failed`. **This is the credential-revocation enforcement payoff: the moment the lease is revoked, the database access it granted is physically impossible.** No grace period, no rollback path, no orphan role left behind.

## Step 5 — Confirm your lease is no longer in Vault's active-leases list

The lease-list lookup is the operator's view of "what credentials are currently issued and still considered live by Vault." Run it and grep for your specific lease suffix — it should NOT be present:

```bash
LEASE_SUFFIX=${LEASE_ID##*/}

kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' \
  vault list sys/leases/lookup/database/creds/uc2-personal-readonly" 2>&1 \
  | grep -F "${LEASE_SUFFIX}" \
  && echo "FAIL: lease ${LEASE_SUFFIX} is still active" \
  || echo "PASS: lease ${LEASE_SUFFIX} is no longer in the active-leases list"
```

Expected output:

```
PASS: lease 7oGTYoP3ASqa87UbpFGlylEp is no longer in the active-leases list
```

The pipeline uses `grep -F` to look for your lease suffix in the listing. If it is found, you'd see `FAIL:`; if not, you see `PASS:`. After Step 3 revoked the lease, Vault removed it from the lookup table — so the `PASS:` line is the expected outcome.

:::expand{header="What does the raw listing look like?"}

To see the underlying Vault output that the pipeline above is filtering, run the inner command without the grep:

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' \
  vault list sys/leases/lookup/database/creds/uc2-personal-readonly" 2>&1
```

Two possible outputs:

- **No other sessions active** — `No value found at sys/leases/lookup/database/creds/uc2-personal-readonly` plus `command terminated with exit code 2`. The exit code is Vault's CLI convention for "empty list", not a real error. On a freshly-deployed workshop cluster with only your terminal session, this is what you'll see.
- **Other sessions still alive** — a `Keys / ---- / <suffix1> / <suffix2> ...` table listing every other live lease. Your `${LEASE_SUFFIX}` will not appear in it. Other suffixes belong to credentials issued by `verify-uc2.sh`, your prior Auth-Code login on page 62 Step 5, or other attendees on the same cluster.

Either way, your specific revoked lease is absent — that's the point Step 5's grep check above confirms unambiguously.
:::

## Step 6 — Find the issuance event in the audit log (Athena)

The Vault audit device streams every API request and response into S3 via Firehose. Cross-reference the lease you just revoked with the lifecycle events recorded for it.

:::alert{type="warning" header="Firehose buffer: ~1 minute lag"}
Firehose buffers audit records for up to 60 seconds before writing them to S3. If the Athena queries below return fewer rows than you expect, wait 60 seconds and re-run them.
:::

Define a small helper to submit a query, wait for completion, and pretty-print the result as an aligned table (empty fields render as `-`):

```bash
# The Glue catalog + Athena 'workshop' workgroup were provisioned in YOUR deploy
# region. Resolve it from the RDS endpoint (kubectl-sourced, so it works regardless
# of your shell's default region or working directory) — never a hardcoded literal,
# per the region contract.
RDS_HOST=$(kubectl get configmap banking-mcp-config -n banking-app -o jsonpath='{.data.RDS_ADDRESS}')
export AWS_REGION=$(echo "${RDS_HOST}" | sed -E 's/.*\.([a-z0-9-]+)\.rds\.amazonaws\.com$/\1/')

athena_query() {
  local Q="$1"
  local QID=$(aws athena start-query-execution --work-group workshop \
    --query-string "$Q" --query 'QueryExecutionId' --output text)
  for i in $(seq 1 30); do
    STATE=$(aws athena get-query-execution --query-execution-id "$QID" \
      --query 'QueryExecution.Status.State' --output text)
    [ "$STATE" = "SUCCEEDED" ] && break
    [ "$STATE" = "FAILED" ] && { aws athena get-query-execution \
      --query-execution-id "$QID" --query 'QueryExecution.Status.StateChangeReason' --output text; return 1; }
    sleep 2
  done
  aws athena get-query-results --query-execution-id "$QID" --output json \
    | jq -r '.ResultSet.Rows[] | [.Data[] | (.VarCharValue // "" | if . == "" then "-" else . end)] | @tsv' \
    | column -t -s $'\t'
}
```

Find the most recent issuance events for `uc2-personal-readonly`. Under the native OAuth resource server model there are no hand-mapped `user_sub` / `role` claim-mappings. Vault's audit device records the delegated OAuth token by its unique **JTI** in `auth.display_name`, and the **Agent Registry** identity it resolved from that token in `auth.metadata['actor_entity_name']` (the `substr(timestamp, 1, 19)` trims nanoseconds for readable display — second precision is plenty for audit correlation):

```bash
athena_query "SELECT
  substr(timestamp, 1, 19) AS time,
  auth.display_name AS identity,
  auth.metadata['actor_entity_name'] AS agent,
  auth.entity_id AS human_entity
FROM workshop_logs.vault_audit
WHERE type = 'response'
  AND request.path = 'database/creds/uc2-personal-readonly'
ORDER BY timestamp DESC
LIMIT 10;"
```

Expected output — one row per recent issuance:

```
time                 identity                                                  agent      human_entity
2026-09-02T23:24:18  root                                                      -          -
2026-09-02T23:17:10  JWT Token with JTI: 5a9564c0-cce3-4442-8a8f-a8d7d1339eb0  agent-uc2  2979d2cd-f25e-2915-a9f8-e6e23d87e047
2026-09-02T23:14:25  JWT Token with JTI: f82c6e27-33d2-4ec2-94e8-29a3b63173a5  agent-uc2  2979d2cd-f25e-2915-a9f8-e6e23d87e047
...
```

Two row patterns appear:

- **`identity=root`, `agent=-`** — the credential was issued via the Vault root token (the inspection commands on the previous pages, including your Step 1 above, and the `verify-uc2.sh` checks). Root-token issuance resolves no Agent Registry identity, so the `agent` column is empty (the helper renders empty fields as `-`).
- **`identity=JWT Token with JTI: <jti>`, `agent=agent-uc2`, and a `human_entity`** — the credential was issued by presenting a real user's IVIA OAuth JWT directly as the `X-Vault-Token` on the `database/creds` read. Vault's OAuth resource server validated the JWT, resolved it to the `agent-uc2` Agent Registry identity, and recorded the token by its unique **JTI** rather than its raw value. **These rows appear after you sign in through the Banking UI and run a banking query** (the browser flow in [OAuth Login Flow](../61-oauth-pkce-flow/)) — one fresh row per tool call. If you have not yet driven a signed-in query, only the `root` rows are present.

Note the `human_entity` column on those rows. It is Vault's own identity entity for the **person**, recorded on the same authorization decision as the agent — two identities on one request, which is what on-behalf-of means. Ask Vault whose it is:

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read -format=json identity/entity/id/<human_entity from above>" \
  | jq '{id: .data.id, name: .data.name}'
```

```json
{
  "id": "2979d2cd-f25e-2915-a9f8-e6e23d87e047",
  "name": "oscar"
}
```

## Step 7 — Find the revocation event for the lease you revoked

The revocation event lives at the path `sys/leases/revoke/<lease_id>`. Query for the specific lease you captured in Step 1:

```bash
athena_query "SELECT
  substr(timestamp, 1, 19) AS time,
  request.path AS revoke_path,
  auth.display_name AS revoked_by
FROM workshop_logs.vault_audit
WHERE type = 'response'
  AND request.path = 'sys/leases/revoke/${LEASE_ID}'
ORDER BY timestamp DESC
LIMIT 5;"
```

Expected output — one row showing your revocation:

```
time                 revoke_path                                                                      revoked_by
2026-05-28T20:37:37  sys/leases/revoke/database/creds/uc2-personal-readonly/UagCrQXfhwPqP16v1wk2fJ1U  root
```

What this proves:

- **`revoke_path` ends with your captured `LEASE_ID`** — the audit log records the exact lease the revoke API call targeted.
- **`time`** — the moment Vault executed the revocation; on a real incident response timeline this is the "session terminated" anchor.
- **`revoked_by=root`** — in this demo *you* invoked the API as the root token, so root is what the audit log records. Revocations the MCP server performs on its own credentials appear the same way but attributed to its ServiceAccount-bound token, exactly identifying the workload that handed the credential back. Query without the `AND request.path = ...` filter to see both kinds side by side.

**The audit-trail story is now closed:** Step 6 shows the ephemeral credential issued on one
authorization decision that names *both* parties — the `agent-uc2` Agent Registry identity and
the human entity it acted for, plus the token's JTI instead of the token itself. Step 7 ties the
revocation to the same `lease_id`. Together they reconstruct "agent-uc2, acting for oscar,
obtained `lease_id` X at 23:17; the MCP server handed X back seconds later" — start-to-end
attribution for a single session, from the Vault plane alone, with no timestamp guessing
involved.

## Step 8 — Watch the MCP server hand a credential back on its own

Steps 1 through 7 revoked a credential *you* issued, as root, from your terminal. That proves the API works. This step proves the workshop's actual claim: that no operator is involved, and every credential the application obtains is returned the moment the query it was issued for finishes.

**Trigger a real query.** In the browser tab where you signed in on the [OAuth Login Flow](../61-oauth-pkce-flow/) page, ask the banking chat:

> What are my account balances?

**Read the MCP server's log.** Two lines tell the whole story — the server authenticating to Vault as itself, and the lease it just used going back:

```bash
kubectl logs -n banking-app -l app=banking-mcp-server --tail=20 \
  | grep -E 'vault_k8s_auth_success|vault_lease_revoked|vault_lease_revoke_'
```

Expected output:

```
vault_k8s_auth_success role=uc2 ttl_seconds=3600
vault_lease_revoked lease_id=database/creds/uc2-personal-readonly/vMLGghj7dj6JbXuwlQC7kH8j
```

`role=uc2` is the Kubernetes auth role bound to `uc2-mcp-server-sa` — the pod's own ServiceAccount, not the user's OAuth token. Your `lease_id` suffix will differ.

**Confirm Vault agrees.** Take the suffix from your own `vault_lease_revoked` line and check it is not in the active-leases list:

```bash
LEASE_SUFFIX=<the suffix from your log line>

kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' \
  vault list sys/leases/lookup/database/creds/uc2-personal-readonly" 2>&1 \
  | grep -F "${LEASE_SUFFIX}" \
  && echo "FAIL: lease ${LEASE_SUFFIX} is still active" \
  || echo "PASS: lease ${LEASE_SUFFIX} is no longer in the active-leases list"
```

Expected output:

```
PASS: lease vMLGghj7dj6JbXuwlQC7kH8j is no longer in the active-leases list
```

Other suffixes will still be listed — those belong to credentials issued by root (your Step 1, the earlier pages, `verify-uc2.sh`), which nothing revokes automatically. That contrast is the point: the ones the application issued are already gone.

**Confirm the audit log names the workload, not you.** Same query as Step 7 without the lease filter, so both kinds of revocation appear side by side:

```bash
athena_query "SELECT
  substr(timestamp, 1, 19) AS time,
  request.path AS revoke_path,
  auth.display_name AS revoked_by
FROM workshop_logs.vault_audit
WHERE type = 'response'
  AND request.path LIKE 'sys/leases/revoke%'
ORDER BY timestamp DESC
LIMIT 6;"
```

Expected output — every revocation the **application** performed is attributed to its ServiceAccount-bound identity. Your own Step 3 revocation appears here too, as `revoked_by = root` with the lease id in the path; the sample run below happened to have two application revocations and no recent root one:

```
time                 revoke_path        revoked_by
2026-09-02T21:10:24  sys/leases/revoke  kubernetes-banking-app-uc2-mcp-server-sa
2026-09-02T15:09:28  sys/leases/revoke  kubernetes-banking-app-uc2-mcp-server-sa
```

Note the two `revoke_path` shapes. The `vault lease revoke` CLI you used in Step 3 addresses the lease in the URL (`sys/leases/revoke/<lease_id>`); the MCP server POSTs to `sys/leases/revoke` with the `lease_id` in the request body. Same endpoint, two calling conventions — which is why this query matches on a prefix and Step 7's matched the exact path.

:::alert{type="info" header="If you see no revocation lines"}
The revoke happens only after a credential is issued, which happens only when a **signed-in** user runs a banking query. If the log shows nothing, you are probably looking at a request that failed before Vault was reached — check for a `get_accounts error` line above it. Firehose also buffers for up to 60 seconds, so re-run the Athena query if the newest row is missing.
:::

:::expand{header="Platform Track — Vault lease lifecycle: explicit revoke vs TTL expiry"}

Vault supports two credential termination paths:

| Path | Trigger | Audit log entry | Postgres role removal |
|---|---|---|---|
| Explicit revocation | `POST /v1/sys/leases/revoke` (this page) | `sys/leases/revoke/<lease_id>` response | Vault runs `revocation_statements` immediately — role dropped within ms |
| TTL expiry | Vault's internal lease expiry timer fires at `lease_duration` | `expired` event | Same `revocation_statements` — role dropped at lease expiry |

The workshop uses **explicit revocation** as the primary path because:

1. **Immediate effect.** With a 15-minute `default_ttl`, relying on TTL alone could leave a valid credential live for up to 15 minutes after a real session ends. Explicit revoke closes the window in milliseconds.
2. **Audit-trail clarity.** The explicit revocation event records the exact moment of session end, attributable to whichever workload called the API. TTL expiry events come from Vault itself with no calling identity.
3. **Defense in depth.** The TTL still acts as a safety net — if the calling workload crashes before issuing the revocation, the credential dies at `T+15m` automatically.

**The `revocation_statements` Vault executes against Postgres are deliberately the inverse of `creation_statements`:**

```sql
-- creation (vault read database/creds/uc2-personal-readonly):
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
ALTER ROLE "{{name}}" SET search_path TO banking, public;
GRANT USAGE ON SCHEMA banking TO "{{name}}";
GRANT SELECT ON ALL TABLES IN SCHEMA banking TO "{{name}}";
ALTER DEFAULT PRIVILEGES IN SCHEMA banking GRANT SELECT ON TABLES TO "{{name}}";

-- revocation (vault lease revoke <lease_id>):
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking FROM "{{name}}";
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA banking FROM "{{name}}";
REVOKE USAGE ON SCHEMA banking FROM "{{name}}";
ALTER DEFAULT PRIVILEGES IN SCHEMA banking REVOKE SELECT ON TABLES FROM "{{name}}";
DROP ROLE IF EXISTS "{{name}}";
```

The `ALTER DEFAULT PRIVILEGES REVOKE` line matches the `ALTER DEFAULT PRIVILEGES GRANT` from issuance. Without that exact mirror, `DROP ROLE` would fail with `cannot be dropped because some objects depend on it` (the GRANT leaves a `pg_default_acl` dependent row that the symmetric REVOKE clears). Symmetric construction means every credential issued is also fully cleanly destroyable — no orphan roles, no escalation surface left behind.
:::

:::expand{header="Agent Developer Track — how the MCP server calls /v1/sys/leases/revoke"}

This is not a pattern to adopt later — it is the code running in the cluster right now. `applications/banking-app/mcp-server/src/vault-client.ts` ships this, and `tools.ts` calls it from the `finally` block of both `get_accounts` and `get_transactions`, so the credential is handed back on the error path as well as the success path:

```typescript
export async function revokeLease(leaseId: string): Promise<boolean> {
  if (!leaseId || leaseId === 'unknown') return false;

  const attempt = async (token: string) =>
    fetch(`${VAULT_ADDR}/v1/sys/leases/revoke`, {
      method: 'POST',
      headers: { 'X-Vault-Token': token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ lease_id: leaseId }),
    });

  try {
    let res = await attempt(await getServiceToken());
    // A 403 means the cached token is gone or was revoked out from under us —
    // log in again once before giving up.
    if (res.status === 403) {
      res = await attempt(await getServiceToken(true));
    }
    if (!res.ok) {
      const body = await res.text();
      console.error(`vault_lease_revoke_failed lease_id=${leaseId} status=${res.status} body=${body}`);
      return false;
    }
    console.log(`vault_lease_revoked lease_id=${leaseId}`);
    return true;
  } catch (err) {
    console.error(`vault_lease_revoke_error lease_id=${leaseId} error=${String(err)}`);
    return false;
  }
}
```

**Why workload identity (k8s auth) and not the user's JWT for the revoke?** The user's JWT may already have expired by the time the query returns, and revoking is not something the user authorized — it is the server disposing of its own resource. `getServiceToken()` logs in at `auth/kubernetes/login` with the pod's projected `uc2-mcp-server-sa` ServiceAccount token, caches the result, and renews it before expiry. The `uc2-personal` policy grants `update` on `sys/leases/revoke` and `read` on `auth/token/lookup-self` — nothing else — so a stolen copy of that token can hand credentials back and learn its own TTL, and can do nothing else.

**Why best-effort?** By the time `finally` runs, the query has succeeded and the caller's data is already on its way back. A revoke failure is logged and swallowed rather than turned into a user-visible error: the credential still expires on its TTL, so the failure degrades to TTL-only behaviour instead of breaking the response. The `console.error` lines above are what an operator alerts on.

**Where does the `lease_id` come from?** `getDbCreds()` returns it alongside the username and password from the `database/creds/uc2-personal-readonly` read, and it stays in the request's local scope — one credential, one query, one revoke. The browser never sees a `lease_id`.

Step 8 below is where you watch all of this happen against your own cluster.
:::

---

### What Would Have Failed

**Without explicit revocation (TTL-only design):** A credential issued at `T+0` would remain valid for up to 15 minutes after a user closes their browser tab. If the credential were leaked (clipboard, log line, memory dump), the attacker would have a 15-minute window of valid access regardless of whether the legitimate session is still alive. Explicit revocation closes the window in milliseconds — leakage windows shrink from minutes to "the time between the leak and the session-end signal".

**Without symmetric `revocation_statements`:** If `creation_statements` adds a `GRANT` or `ALTER DEFAULT PRIVILEGES` but `revocation_statements` doesn't remove the symmetric counterpart, `DROP ROLE` aborts with a dependent-object error. Vault marks the lease "failed to revoke" and retries forever — the orphan Postgres role accumulates with each revocation attempt, and the lease never closes cleanly. Symmetric construction (every GRANT has a matching REVOKE) is what guarantees the lifecycle ends.

**Without audit logging of the revoke API:** The Step 7 query becomes impossible. The revocation event exists in operational reality (the role is gone, the lease lookup fails) but there's no immutable record of *who* terminated the session *when*. For OBJ-5 (audit attribution) the revoke event is as important as the issuance event — together they bracket exactly the window of credential validity that an incident investigation would need to know about.
