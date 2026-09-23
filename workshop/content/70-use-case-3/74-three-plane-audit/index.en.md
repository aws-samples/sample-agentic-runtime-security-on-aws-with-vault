---
title: 'Three-Plane Audit Correlation'
weight: 74
---

### Objective 5 · Correlated audit evidence

Three systems logged your refund independently and none of them knew about the others. This page joins them on one shared id and answers the question people actually ask after an incident: *who authorized this, when, against what, and how long did the credential live?*

Each plane records its own half: IVIA *who approved*, Vault *which agent was authorized, for which human, scoped to which path*, Postgres *the write that landed*. They join on the agent's `request_id`, which reaches Vault because the agent stamps it on the credential request as an `X-Correlation-Id` header. The `audit_correlation` VIEW was created during deployment — you only query it.

## One row, all five objectives

| Objective | Column | What It Proves |
|---|---|---|
| OBJ-1 — Verifiable agent identity | `vault_principal` + `vault_human_entity_id` | Vault resolved a registered agent acting for a specific human identity entity |
| OBJ-2 — No standing privileges | `db_credential_ttl` | DB credentials lived for 5 minutes only |
| OBJ-3 — Action tied to user intent | `user_approved_sub` + `ciba_binding_message` | The user approved this exact `request_id` out-of-band |
| OBJ-4 — Enforcement at point of use | `vault_agent_registry_id` + `vault_rar_path` | Vault resolved the agent from the Agent Registry and narrowed the token to an exact path per request |
| OBJ-5 — Correlated audit evidence | `request_id` — the same value in all three planes | One forensic row spans approval, authorization, and the database write, joined on a shared id rather than inferred from timing |

## Set up the query helpers

**Why:** Athena is asynchronous — start, poll, fetch. These four helpers wrap that so the rest of the page reads as one command per question. The `workshop` workgroup already has a result location, so there is no bucket to resolve.

```bash
# The Glue catalog + Athena 'workshop' workgroup were provisioned in YOUR deploy
# region (resolved from Terraform state — never a hardcoded literal, per the region
# contract). Point the CLI at that region so the workgroup and the workshop_logs
# database resolve regardless of your shell's default region.
export AWS_REGION="$(terraform -chdir=infrastructure output -raw region)"

# Run a query in the 'workshop' workgroup, wait for it, echo the execution id
athena_run() {
  local QID=$(aws athena start-query-execution --work-group workshop \
    --query-string "$1" --query 'QueryExecutionId' --output text)
  for i in $(seq 1 30); do
    local S=$(aws athena get-query-execution --query-execution-id "$QID" \
      --query 'QueryExecution.Status.State' --output text)
    [ "$S" = "SUCCEEDED" ] && { echo "$QID"; return 0; }
    [ "$S" = "FAILED" ] && { aws athena get-query-execution --query-execution-id "$QID" \
      --query 'QueryExecution.Status.StateChangeReason' --output text >&2; return 1; }
    sleep 2
  done
}

# Multi-row aligned table
athena_query() { aws athena get-query-results --query-execution-id "$(athena_run "$1")" \
  --output json | jq -r '.ResultSet.Rows[] | [.Data[] | (.VarCharValue // "-")] | @tsv' | column -t -s $'\t'; }

# Single row, vertical (field -> value)
athena_record() { aws athena get-query-results --query-execution-id "$(athena_run "$1")" \
  --output json | jq -r '.ResultSet.Rows as $r | range(0; ($r[0].Data|length)) as $i
    | "\($r[0].Data[$i].VarCharValue)\t\($r[1].Data[$i].VarCharValue // "-")"' | column -t -s $'\t'; }

# First value only (capture into a variable)
athena_scalar() { aws athena get-query-results --query-execution-id "$(athena_run "$1")" \
  --query 'ResultSet.Rows[1].Data[0].VarCharValue' --output text; }
```

**Step 1:** Capture a `request_id` into `REQUEST_ID`. The IVIA decision plane is the anchor — every approved refund writes one record there. This grabs the most recent approval (the refund you just made):

```bash
REQUEST_ID=$(athena_scalar "SELECT request_id FROM workshop_logs.ivia_decisions
  WHERE request_id <> '' ORDER BY timestamp DESC LIMIT 1")
echo "request_id: ${REQUEST_ID}"
```

To trace a **different** refund — for example, one you approved as Jaime versus Oscar — list the recent approvals (the `user_identity` column tells you who approved each), then set `REQUEST_ID` to the id you want:

```bash
athena_query "SELECT request_id, user_identity, substr(timestamp,1,19) AS time
  FROM workshop_logs.ivia_decisions
  WHERE request_id <> ''
  ORDER BY timestamp DESC LIMIT 5"
# REQUEST_ID=2f50b532-2ea2-4eef-b591-71250b5470c3   # <- set to the id you want
```

**Step 2:** Run the correlation query against that `request_id`. `athena_record` prints the one wide row vertically, and `substr(...,1,19)` trims the timestamps to second precision for readability:

```bash
athena_record "SELECT
  request_id,
  substr(approval_time,1,19)   AS approval_time,
  user_approved_sub,
  ciba_binding_message,
  substr(vault_auth_time,1,19) AS vault_auth_time,
  vault_principal,
  vault_human_entity_id,
  vault_agent_registry_id,
  vault_rar_path,
  substr(db_write_time,1,19)   AS db_write_time,
  db_command,
  db_credential_ttl
FROM workshop_logs.audit_correlation WHERE request_id = '${REQUEST_ID}' LIMIT 1"
```

You should see one row spanning all three planes — the user who approved, the agent that authenticated and the claims it was bound to, the database write, and the credential TTL:

```text
request_id               21e88164-d561-43c8-9157-e6c8f732d070
approval_time            2026-09-02T22:21:50
user_approved_sub        jaime
ciba_binding_message     21e88164-d561-43c8-9157-e6c8f732d070
vault_auth_time          2026-09-02T22:21:49
vault_principal          uc3-actor (on behalf of jaime)
vault_human_entity_id    6edd531a-371a-7bb1-2290-fe520b73e0e8
vault_agent_registry_id  uc3-actor
vault_rar_path           database/creds/uc3-refund-writer
db_write_time            2026-09-02 22:21:50
db_command               WRITE,INSERT
db_credential_ttl        300
```

Your ids and timestamps differ; the shape does not. Read the three timestamps together — Vault
authorized the credential at `22:21:49`, the approval and the database write both landed at
`22:21:50`. The whole privileged window is about a second wide, and the credential that opened
it expires 300 seconds later whether or not anything else happens.

`vault_human_entity_id` is the column that answers *which person was this done for?* — Vault's own identity entity for the human, recorded on the same authorization decision as the agent, not inferred from the approval log sitting next to it. The last section turns that id into a name.

## The same query in the Athena console

**Why:** Same result without the CLI, if that is how your audit team works.

**Step 1:** Navigate to **Athena** > **Query editor** and select the `workshop_logs` database from the dropdown.

**Step 2:** Find a recent `request_id` to investigate:

```sql
SELECT request_id, user_identity, timestamp
FROM ivia_decisions
WHERE request_id <> ''
ORDER BY timestamp DESC
LIMIT 5
```

Copy the `request_id` of the refund you want to trace (the `user_identity` column tells you who approved each one).

**Step 3:** Query the correlation VIEW. Paste the `request_id` you copied in place of the placeholder below:

```sql
SELECT *
FROM audit_correlation
WHERE request_id = 'PASTE_REQUEST_ID_HERE'
```

## Read the Vault record yourself

**Why:** The correlation row is a summary somebody else wrote. Open the underlying Vault audit event and see what Vault actually validated — the claims, the issuer, the exact RAR it enforced.

`REQUEST_ID` is still set from above. The row is wide, so print it vertically:

```bash
echo "tracing: ${REQUEST_ID}"

athena_record "SELECT
  auth.entity_id                                  AS human_entity,
  auth.metadata['actor_entity_name']              AS agent,
  auth.metadata['jwt_audience_claim']             AS audience,
  auth.metadata['jwt_issuer']                     AS issuer,
  auth.metadata['jwt_unique_id']                  AS jti,
  auth.metadata['jwt_authorization_details']      AS authorization_details,
  element_at(element_at(request.headers, 'x-correlation-id'), 1) AS correlation_id
FROM workshop_logs.vault_audit
WHERE type = 'response'
  AND request.path = 'database/creds/uc3-refund-writer'
  AND (error IS NULL OR error = '')
  AND element_at(element_at(request.headers, 'x-correlation-id'), 1) = '${REQUEST_ID}'
LIMIT 1;"
```

The `error IS NULL` line is not boilerplate, and it is worth understanding before you read the
result. Your Vault cluster runs three nodes: one **active**, two **performance standbys**.
Standbys serve reads, but issuing a database credential creates a lease, and only the active
node may do that. So when the agent's request happens to land on a standby, that standby audits
the request, answers `please forward to the active node`, and redirects; the client follows the
redirect and the active node audits the same request again and issues the credential. Both hops
are genuine audit records and both carry your correlation header — but only one of them issued
anything, and the refused hop has no `auth` block at all. Filtering on `error` selects the hop
that did the work. Drop that line and re-run the query to see both.

```text
human_entity           6edd531a-371a-7bb1-2290-fe520b73e0e8
agent                  uc3-actor
audience               ["uc3-actor"]
issuer                 https://wrp.kp3v5q.100-62-248-6.nip.io
jti                    06d75bf8-3a8b-4d69-a110-001f424e05ec
authorization_details  [{"type":"refund_approval"},{"capabilities":["read"],"path":"database/creds/uc3-refund-writer","type":"vault:path_access"}]
correlation_id         21e88164-d561-43c8-9157-e6c8f732d070
```

Six things are worth finding in that output:

- **`human_entity`** — a Vault identity entity id. This is the human the token was issued for. The claim that Vault records only the agent and never the person is simply false, and the next command proves whose id it is.
- **`agent`** — `uc3-actor`, the Agent Registry entity Vault resolved from the token's `act.sub`. Two identities, one request: that *is* on-behalf-of.
- **`audience`** — the token names `uc3-actor` as its audience. A token minted for a different audience is not accepted here.
- **`issuer`** — your IVIA OIDC Provider. Vault validated the signature against that issuer's JWKS before any of the above mattered.
- **`jti`** — the token's unique id. This is what the audit trail names instead of the raw token, so the record identifies the credential without containing it.
- **`authorization_details`** — the `vault:path_access` entry naming `database/creds/uc3-refund-writer` with capability `read`, alongside the `refund_approval` type. This is the per-request narrowing Vault enforced, recorded in the same breath as the request it authorized.

### Resolve the human entity to a name

The entity id is deliberately opaque in the log. Ask Vault who it is:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read -format=json identity/entity/id/<human_entity from above>" \
  | jq '{id: .data.id, name: .data.name}'
```

Expected output — the person who tapped Approve on their phone:

```json
{
  "id": "6edd531a-371a-7bb1-2290-fe520b73e0e8",
  "name": "jaime"
}
```

The agent has an identity entity too, but the audit record names it rather than giving you its
id — so look that one up by name:

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read -format=json identity/entity/name/uc3-actor" \
  | jq '{id: .data.id, name: .data.name}'
```

```json
{
  "id": "392ac41d-fb15-8041-2d9d-869c4c48517b",
  "name": "uc3-actor"
}
```

That pair — a named human and a named agent on one authorization decision, with the exact path it was narrowed to — is the record an incident responder needs, and it came out of Vault without any application help beyond the correlation header.

:::alert{type="info" header="Why the correlation header exists at all"}
Everything above comes from Vault's own view of the token. The one thing Vault has no way to know is *which refund* this was, because `request_id` is the application's concept and never appears in the token — IBM Verify does not carry the consent-time detail through the exchange (see the [CIBA Approval Flow](../71-ciba-approval-flow/) page). So the agent sends it explicitly, as an `X-Correlation-Id` header on the credential request, and Vault records it because a `vault_audit_request_header` resource allowlists that header with `hmac = false`. Without the allowlist Vault drops the header silently; without the header the Vault plane could only be matched to the other two by credential path and a time window, which stops being trustworthy the moment two refunds overlap.
:::

## Interpreting the Result

A complete row demonstrates that:

1. The same `request_id` appears in **all three** logs: the IVIA decision log (who approved), the Vault audit log (which agent was authorized, for which human, scoped to which path), and the pgaudit log (the write that landed in `banking.refunds`). The Vault plane carries it because the agent sends it as `X-Correlation-Id` and Vault is configured to audit that header — so the row is an equality join on one id, not three logs lined up by clock.
2. The `approval_time`, `vault_auth_time`, and `db_write_time` columns show a linear causal chain — approval before auth before write.
3. The `db_credential_ttl` carries the integer lease TTL in seconds (300 = 5 minutes) the agent observed when Vault issued the per-refund database credential — proof the credential expires shortly after the write, not a standing one.
4. The `vault_agent_registry_id` column shows the exact agent (`uc3-actor`) Vault resolved from the delegated token's `act.sub` against the Agent Registry, and `vault_rar_path` shows the exact path (`database/creds/uc3-refund-writer`) the per-request `vault:path_access` RAR narrowed the token to — the enforcement Vault applied at the point of use, provable and not assumed.

:::alert{header="How the approved amount is proven — consent-bound by correlation" type="info"}
The amount the user approved (e.g. `$88.30`) is **not** a column in this VIEW, and it is **not** a Vault-enforced token scope — ISVAOP 25.10 does not expose the consent-time RAR amount at the token-exchange stage (see the [RAR Ceiling](../72-configure-rar-ceiling/) page). Instead the amount is **consent-bound by the shared `request_id`**: there is exactly **one** CIBA approval and exactly **one** `banking.refunds` write under that `request_id`, and the refund row itself carries the amount. Because the correlation row proves a strict 1:1 binding between the user's out-of-band approval and a single, time-boxed, RAR-gated DB write, the amount written **is** the amount approved — an agent cannot write a different or additional amount under that approval without breaking the correlation. To read the dollar figure directly, query the `banking.refunds` row for that `request_id`. Note this is a **Postgres (RDS) table, not an Athena catalog** — run it with the `psql` debug-pod pattern from the [bypass test](../73-bypass-test/), not in the Athena editor:

```sql
SELECT request_id, refund_id, account_id, transaction_id, amount, currency, approved_by, created_at
FROM banking.refunds
WHERE request_id = '${REQUEST_ID}';
```
:::

This is the answer to the question the OscarVault International (OVI) demo poses: **"Who authorized this action, through which agent, against what system, for what class of action, and can we prove the credentials have since expired?"**
