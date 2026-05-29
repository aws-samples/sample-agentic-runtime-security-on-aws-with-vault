---
title: 'Three-Plane Audit Correlation'
weight: 74
---

Each plane logs the same refund independently: IVIA records *who approved*, Vault records *which agent authenticated and the claims it was bound to*, and Postgres records *the write that landed*. The `audit_correlation` Athena VIEW stitches all three together on the shared `request_id`, so a single query returns one forensic row spanning approval, authentication, and database write. It was created automatically during Use Case 3 deployment — you only query it.

## The Pedagogical Money Shot

Use Case 3 culminates in a single Athena query that answers all five workshop objectives in one row:

| Objective | Column | What It Proves |
|---|---|---|
| OBJ-1 — Verifiable agent identity | `vault_principal` | The agent authenticated with a specific Vault role |
| OBJ-2 — No standing privileges | `db_credential_ttl` | DB credentials lived for 5 minutes only |
| OBJ-3 — Action tied to user intent | `user_approved_sub` + `ciba_binding_message` | The user approved this exact `request_id` out-of-band |
| OBJ-4 — Enforcement at point of use | `vault_bound_claim_may_act` + `vault_bound_claim_rar_type` | Vault enforced `may_act` and `authorization_details` at auth time |
| OBJ-5 — Correlated audit evidence | `request_id` present in all three planes | IVIA + Vault + pgaudit share a single traceable identifier |

## Run the Correlation Query — CLI

The `workshop` Athena workgroup ships with a preconfigured query-result location, so you do **not** need to resolve an S3 bucket. Define a base helper that runs a query and waits for it, plus three thin wrappers — `athena_query` (aligned multi-row table), `athena_record` (a single row printed vertically, `field → value`, ideal for the wide correlation row), and `athena_scalar` (just the first value, for capturing into a variable):

```bash
# Run a query in the 'workshop' workgroup, wait for it, echo the execution id
athena_run() {
  local QID=$(aws athena start-query-execution --region us-west-2 --work-group workshop \
    --query-string "$1" --query 'QueryExecutionId' --output text)
  for i in $(seq 1 30); do
    local S=$(aws athena get-query-execution --region us-west-2 --query-execution-id "$QID" \
      --query 'QueryExecution.Status.State' --output text)
    [ "$S" = "SUCCEEDED" ] && { echo "$QID"; return 0; }
    [ "$S" = "FAILED" ] && { aws athena get-query-execution --region us-west-2 --query-execution-id "$QID" \
      --query 'QueryExecution.Status.StateChangeReason' --output text >&2; return 1; }
    sleep 2
  done
}

# Multi-row aligned table
athena_query() { aws athena get-query-results --region us-west-2 --query-execution-id "$(athena_run "$1")" \
  --output json | jq -r '.ResultSet.Rows[] | [.Data[] | (.VarCharValue // "-")] | @tsv' | column -t -s $'\t'; }

# Single row, vertical (field -> value)
athena_record() { aws athena get-query-results --region us-west-2 --query-execution-id "$(athena_run "$1")" \
  --output json | jq -r '.ResultSet.Rows as $r | range(0; ($r[0].Data|length)) as $i
    | "\($r[0].Data[$i].VarCharValue)\t\($r[1].Data[$i].VarCharValue // "-")"' | column -t -s $'\t'; }

# First value only (capture into a variable)
athena_scalar() { aws athena get-query-results --region us-west-2 --query-execution-id "$(athena_run "$1")" \
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
  vault_path,
  vault_bound_claim_may_act,
  vault_bound_claim_rar_type,
  substr(db_write_time,1,19)   AS db_write_time,
  db_command,
  db_credential_ttl
FROM workshop_logs.audit_correlation WHERE request_id = '${REQUEST_ID}' LIMIT 1"
```

You should see one row spanning all three planes — the user who approved, the agent that authenticated and the claims it was bound to, the database write, and the credential TTL:

```text
request_id                  2f50b532-2ea2-4eef-b591-71250b5470c3
approval_time               2026-05-29T15:20:47
user_approved_sub           jaime
ciba_binding_message        2f50b532-2ea2-4eef-b591-71250b5470c3
vault_auth_time             2026-05-29T15:20:47
vault_principal             jwt-jaime
vault_path                  database/creds/uc3-refund-writer
vault_bound_claim_may_act   uc3-actor
vault_bound_claim_rar_type  refund_approval
db_write_time               2026-05-29 15:20:47
db_command                  WRITE,INSERT
db_credential_ttl           300
```

Every field maps directly to one of the five workshop objectives — `vault_principal` (verifiable agent identity), `db_credential_ttl` of `300` (no standing privilege, 5-minute lease), `user_approved_sub` (action tied to user intent), `vault_bound_claim_may_act` + `vault_bound_claim_rar_type` (enforcement at point of use), and the shared `request_id` across all three planes (correlated audit evidence).

## Run the Correlation Query — Athena Console

Prefer the AWS Console? The same query runs in the Athena query editor.

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

## Interpreting the Result

A complete row demonstrates that:

1. The same `request_id` appears in the IVIA decision log (user approved), the Vault audit log (agent authenticated with bound claims enforced), and the pgaudit log (data was written to `banking.refunds`).
2. The `approval_time`, `vault_auth_time`, and `db_write_time` columns show a linear causal chain — approval before auth before write.
3. The `db_credential_ttl` carries the integer lease TTL in seconds (300 = 5 minutes) the agent observed when Vault issued the per-refund database credential — proof the credential expires shortly after the write, not a standing one.
4. The `vault_bound_claim_may_act` column shows the exact service account that was the actor — provable, not assumed.

This is the answer to the question the OscarVault International (OVI) demo poses: **"Who authorized this action, through which agent, against what system, and can we prove the credentials have since expired?"**
