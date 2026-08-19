---
title: 'Three-Plane Audit Correlation'
weight: 74
---

Each plane logs the same refund independently: IVIA records *who approved*, Vault records *which agent authenticated — by its Agent Registry identity — and the exact path it was scoped to*, and Postgres records *the write that landed*. The `audit_correlation` Athena VIEW stitches all three together: `request_id` is the shared key between the IVIA approval and the Postgres write, and the Vault authentication binds into the same row by its credential path and its sub-second time-proximity to the approval. A single query returns one forensic row spanning approval, authentication, and database write. It was created automatically during Use Case 3 deployment — you only query it.

Under the native OAuth resource server model, the Vault audit event no longer carries a hand-rolled `may_act` bound-claim; it carries the **agent-registry** identity Vault resolved from the delegated token's `act.sub` claim (`uc3-actor`) and the per-request `vault:path_access` path Vault enforced. Those two fields are what surface in the correlation row below.

## The Pedagogical Money Shot

Use Case 3 culminates in a single Athena query that answers all five workshop objectives in one row:

| Objective | Column | What It Proves |
|---|---|---|
| OBJ-1 — Verifiable agent identity | `vault_principal` | The agent authenticated with a specific Vault role |
| OBJ-2 — No standing privileges | `db_credential_ttl` | DB credentials lived for 5 minutes only |
| OBJ-3 — Action tied to user intent | `user_approved_sub` + `ciba_binding_message` | The user approved this exact `request_id` out-of-band |
| OBJ-4 — Enforcement at point of use | `vault_agent_registry_id` + `vault_rar_path` | Vault resolved the agent from the Agent Registry and narrowed the token to an exact path per request |
| OBJ-5 — Correlated audit evidence | `request_id` (IVIA approval ↔ pgaudit write) + Vault bound by path & time | One forensic row spans approval, authentication, and the database write |

## Run the Correlation Query — CLI

The `workshop` Athena workgroup ships with a preconfigured query-result location, so you do **not** need to resolve an S3 bucket. Define a base helper that runs a query and waits for it, plus three thin wrappers — `athena_query` (aligned multi-row table), `athena_record` (a single row printed vertically, `field → value`, ideal for the wide correlation row), and `athena_scalar` (just the first value, for capturing into a variable):

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
  vault_agent_registry_id,
  vault_rar_path,
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
vault_principal             uc3-actor (on behalf of jaime)
vault_agent_registry_id     uc3-actor
vault_rar_path              database/creds/uc3-refund-writer
db_write_time               2026-05-29 15:20:47
db_command                  WRITE,INSERT
db_credential_ttl           300
```

Every field maps directly to one of the five workshop objectives — `vault_principal` (verifiable agent identity), `db_credential_ttl` of `300` (no standing privilege, 5-minute lease), `user_approved_sub` (action tied to user intent), `vault_agent_registry_id` + `vault_rar_path` (enforcement at point of use — the Agent Registry identity Vault resolved and the exact path it scoped the token to), and the correlation across all three planes — `request_id` shared by the IVIA approval and the Postgres write, with the Vault authentication bound in by credential path and time-proximity (correlated audit evidence).

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

1. The same `request_id` appears in the IVIA decision log (user approved) and the pgaudit log (data was written to `banking.refunds`). The Vault audit log (agent authenticated by its Agent Registry identity and scoped to an exact path per request) deliberately records neither the `request_id` nor the human subject — it is correlated into the same forensic row by its credential path and the sub-second time-proximity of its authentication to the approval.
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
