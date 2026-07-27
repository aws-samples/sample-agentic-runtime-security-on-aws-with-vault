---
title: 'Credential Revocation'
weight: 65
---

## Overview

In this module you observe the full credential lifecycle for a Use Case 2 session: a Postgres credential is issued, used to confirm its existence, then explicitly revoked, and you verify three things in succession — (a) the Postgres role is gone, (b) Vault's active-leases list no longer contains your lease, (c) both the issuance and the revocation appear in the audit log keyed by `lease_id`.

**The production code path** is `POST /v1/sys/leases/revoke` against Vault. An MCP server, banking-agent, or any session-end handler calls that endpoint when a session terminates. In this page you exercise the same API directly via the `vault lease revoke` CLI — identical mechanism, no UI dependency, immediate evidence.

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
SECRET_ID=$(aws secretsmanager list-secrets \
  --query 'SecretList[?contains(Name,`rds!db`)].Name | [0]' --output text)
MASTER_USER=$(aws secretsmanager get-secret-value --secret-id "${SECRET_ID}" \
  --query SecretString --output text | jq -r '.username')
MASTER_PASS=$(aws secretsmanager get-secret-value --secret-id "${SECRET_ID}" \
  --query SecretString --output text | jq -r '.password')
RDS_HOST=$(kubectl get configmap banking-mcp-config -n banking-app -o jsonpath='{.data.RDS_ADDRESS}')

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
# region (resolved from Terraform state — never a hardcoded literal, per the region
# contract). Point the CLI at that region so the workgroup and the workshop_logs
# database resolve regardless of your shell's default region.
export AWS_REGION="$(terraform -chdir=infrastructure output -raw region)"

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

Find the most recent issuance events for `uc2-personal-readonly`. Under the native OAuth resource server model there are no hand-mapped `user_sub` / `role` claim-mappings — Vault resolves the requester to a Vault **entity** from the presented JWT's `sub` claim (`user_claim = sub`). `auth.display_name` and `auth.entity_id` carry that resolved identity (the `substr(timestamp, 1, 19)` trims nanoseconds for readable display — second precision is plenty for audit correlation):

```bash
athena_query "SELECT
  substr(timestamp, 1, 19) AS time,
  auth.display_name AS identity,
  auth.entity_id AS entity_id
FROM workshop_logs.vault_audit
WHERE type = 'response'
  AND request.path = 'database/creds/uc2-personal-readonly'
ORDER BY timestamp DESC
LIMIT 10;"
```

Expected output — one row per recent issuance:

```
time                 identity  entity_id
2026-07-24T19:57:26  root      -
2026-07-24T19:55:18  root      -
2026-07-24T18:03:59  root      -
...
```

Two row patterns appear:

- **`identity=root`, `entity_id=-`** — the credential was issued via the Vault root token (the inspection commands on the previous pages, including your Step 1 above, and the `verify-uc2.sh` checks). Root-token issuance resolves no Vault entity, so `entity_id` is empty (the helper renders empty fields as `-`).
- **`identity=<sub>` (e.g. `oscar` / `jaime`), with a populated `entity_id`** — the credential was issued by presenting a real user's IVIA OAuth JWT directly as the `X-Vault-Token` on the `database/creds` read. Vault's OAuth resource server resolved the human `sub` to a Vault entity (`user_claim = sub`); that resolved entity is the OBJ-5 audit evidence tying the credential to the originating user. **These rows appear after you sign in through the Banking UI and run a banking query** (the browser flow in [OAuth Login Flow](../61-oauth-pkce-flow/)) — one fresh row per tool call. The exact `identity` / `entity_id` values are recorded live at that moment; if you have not yet driven a signed-in query, only the `root` rows are present.

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
- **`revoked_by=root`** — in this demo you invoked the API as the root token. In a production flow this would be the service-account-bound Vault token the MCP server uses (`display_name=token-uc2-mcp-server-sa` or similar) — exactly identifying the workload that ended the session.

**The audit-trail story is now closed:** Step 6 ties the original credential to a user identity (the resolved `sub` entity); Step 7 ties the revocation to the same `lease_id`. Anyone analysing the audit log can reconstruct "Oscar logged in at 19:24, got `lease_id` X, the MCP server revoked X at 20:19" — start-to-end attribution for a single session.

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

:::expand{header="Agent Developer Track — calling /v1/sys/leases/revoke from a production session-end handler"}

In a production agent, the session-end handler calls Vault's revoke API directly. Here is the same flow expressed in TypeScript (the same pattern the banking-app MCP server would use on logout or token expiry):

```typescript
async function revokeLeaseOnSessionEnd(leaseId: string): Promise<void> {
  // Re-authenticate with the workload's k8s ServiceAccount token (not the
  // user's JWT) — keeps the revoke path working even if the user's JWT has
  // already expired by the time the session-end handler runs.
  const vaultToken = await vaultClient.loginWithK8sSA('uc2-mcp-server-sa');

  const resp = await fetch(`${VAULT_ADDR}/v1/sys/leases/revoke`, {
    method: 'POST',
    headers: {
      'X-Vault-Token': vaultToken,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ lease_id: leaseId }),
  });

  if (!resp.ok) {
    // Log but don't throw — the lease will still TTL-expire as a safety net.
    console.warn(`Revoke failed for ${leaseId}: ${resp.status}`);
  }
}
```

**Why workload identity (k8s auth) and not the user's JWT for the revoke?** The user's JWT might have already expired (browser tab idle for hours, refresh token gone). The MCP server's Kubernetes ServiceAccount is always available — its `uc2-mcp-server-sa` token authenticates to Vault via the `uc2` k8s auth role. The `uc2-personal` policy grants `update` on `sys/leases/revoke` exactly for this purpose.

**Where does the `lease_id` come from?** The MCP server stored it in its per-request context the moment it issued the credential (the `lease_id` field returned from `vault read database/creds/uc2-personal-readonly`). On session end the handler revokes whatever leases it tracked. Session state is server-side only — the browser never sees a `lease_id`.

The audit-log query in Step 7 is exactly the operator's tool for confirming that a production session-end handler is calling this API as expected: the revocation events should appear with `display_name=token-uc2-mcp-server-sa` (the workload identity) and a `lease_id` that joins back to a user JWT issuance from the same time window.
:::

---

### What Would Have Failed

**Without explicit revocation (TTL-only design):** A credential issued at `T+0` would remain valid for up to 15 minutes after a user closes their browser tab. If the credential were leaked (clipboard, log line, memory dump), the attacker would have a 15-minute window of valid access regardless of whether the legitimate session is still alive. Explicit revocation closes the window in milliseconds — leakage windows shrink from minutes to "the time between the leak and the session-end signal".

**Without symmetric `revocation_statements`:** If `creation_statements` adds a `GRANT` or `ALTER DEFAULT PRIVILEGES` but `revocation_statements` doesn't remove the symmetric counterpart, `DROP ROLE` aborts with a dependent-object error. Vault marks the lease "failed to revoke" and retries forever — the orphan Postgres role accumulates with each revocation attempt, and the lease never closes cleanly. Symmetric construction (every GRANT has a matching REVOKE) is what guarantees the lifecycle ends.

**Without audit logging of the revoke API:** The Step 7 query becomes impossible. The revocation event exists in operational reality (the role is gone, the lease lookup fails) but there's no immutable record of *who* terminated the session *when*. For OBJ-5 (audit attribution) the revoke event is as important as the issuance event — together they bracket exactly the window of credential validity that an incident investigation would need to know about.
