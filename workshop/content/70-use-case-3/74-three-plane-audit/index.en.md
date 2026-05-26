---
title: 'Three-Plane Audit Correlation'
weight: 74
---

## The Pedagogical Money Shot

Use Case 3 culminates in a single Athena query that answers all five workshop objectives in one row:

| Objective | Column | What It Proves |
|---|---|---|
| OBJ-1 — Verifiable agent identity | `vault_principal` | The agent authenticated with a specific Vault role |
| OBJ-2 — No standing privileges | `db_credential_ttl` | DB credentials lived for 5 minutes only |
| OBJ-3 — Action tied to user intent | `user_approved_sub` + `ciba_binding_message` | The user approved this exact `request_id` out-of-band |
| OBJ-4 — Enforcement at point of use | `vault_bound_claim_may_act` + `vault_bound_claim_rar_type` | Vault enforced `may_act` and `authorization_details` at auth time |
| OBJ-5 — Correlated audit evidence | `request_id` present in all three planes | IVIA + Vault + pgaudit share a single traceable identifier |

## The `audit_correlation` VIEW

This VIEW is **created for you automatically** when Use Case 3 is deployed and verified (`verify-uc3.sh` executes the DDL from the Terraform-managed Athena named query). You do **not** need to create it — it is shown here so you can see how the three log streams are joined in Athena using `request_id` as the primary key:

```sql
CREATE OR REPLACE VIEW audit_correlation AS
SELECT
    ivia.request_id,
    ivia.timestamp                                                AS approval_time,
    ivia.user_identity                                            AS user_approved_sub,
    ivia.request_id                                               AS ciba_binding_message,
    vault.timestamp                                               AS vault_auth_time,
    vault.auth.display_name                                       AS vault_principal,
    vault.request.path                                            AS vault_path,
    vault.auth.metadata['may_act_sub']                            AS vault_bound_claim_may_act,
    ivia.authorization_details[1].type                            AS vault_bound_claim_rar_type,
    regexp_extract(rds.line, '^([0-9-]+ [0-9:]+ UTC)', 1)        AS db_write_time,
    regexp_extract(rds.line, 'AUDIT: SESSION,[0-9]+,[0-9]+,([A-Z]+,[A-Z]+),', 1) AS db_command,
    ivia.db_credential_ttl                                        AS db_credential_ttl
FROM workshop_logs.ivia_decisions ivia
JOIN workshop_logs.vault_audit vault
    ON vault.auth.display_name = 'jwt-' || ivia.user_identity
    AND vault.request.path = 'database/creds/uc3-refund-writer'
    AND vault.type = 'response'
    AND ABS(to_unixtime(from_iso8601_timestamp(vault.timestamp))
          - to_unixtime(from_iso8601_timestamp(ivia.timestamp))) < 30
LEFT JOIN workshop_logs.pgaudit_logs rds
    ON regexp_extract(rds.line, 'uc3_request_id=([0-9a-f-]{36})', 1) = ivia.request_id;
```

## Run the Athena Query

**Step 1:** In the AWS Console, navigate to **Athena** > **Query editor**.

**Step 2:** Select the `workshop_logs` database from the dropdown.

:::alert{header="The VIEW already exists" type="info"}
The `audit_correlation` VIEW was created automatically during Use Case 3 deployment. You do not create it — your only job here is to query it and read the forensic row.
:::

**Step 3:** Find a `request_id` from the UC3 agent logs:

```bash
# Retrieve a recent request_id from CloudWatch
aws logs filter-log-events \
  --log-group-name /workshop/agent-trace \
  --region "${AWS_REGION}" \
  --filter-pattern "{ $.event_type = \"refund_approved\" }" \
  --query 'events[0].message' \
  --output text | jq -r .request_id
```

**Step 4:** Query the correlation VIEW:

```sql
SELECT *
FROM audit_correlation
WHERE request_id = 'YOUR-REQUEST-ID-HERE'
```

**Step 5:** Inspect the result. One row should contain all three plane timestamps, the user who approved, the agent that acted, the database write operation (`WRITE,INSERT`), and the credential TTL. Every column maps directly to one of the five workshop objectives.

## CLI Alternative

```bash
# Start Athena query and get execution ID
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT * FROM audit_correlation WHERE request_id = 'YOUR-REQUEST-ID-HERE' LIMIT 1" \
  --query-execution-context Database=workshop_logs \
  --result-configuration OutputLocation="s3://YOUR-LOG-BUCKET/athena-results/" \
  --region "${AWS_REGION}" \
  --query 'QueryExecutionId' --output text)

# Wait for completion
aws athena get-query-execution \
  --query-execution-id "${QUERY_ID}" \
  --region "${AWS_REGION}" \
  --query 'QueryExecution.Status.State' --output text

# Retrieve results
aws athena get-query-results \
  --query-execution-id "${QUERY_ID}" \
  --region "${AWS_REGION}" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue'
```

## Interpreting the Result

A complete row demonstrates that:

1. The same `request_id` appears in the IVIA decision log (user approved), the Vault audit log (agent authenticated with bound claims enforced), and the pgaudit log (data was written to `banking.refunds`).
2. The `approval_time`, `vault_auth_time`, and `db_write_time` columns show a linear causal chain — approval before auth before write.
3. The `db_credential_ttl` carries the integer lease TTL in seconds (300 = 5 minutes) the agent observed when Vault issued the per-refund database credential — proof the credential expires shortly after the write, not a standing one.
4. The `vault_bound_claim_may_act` column shows the exact service account that was the actor — provable, not assumed.

This is the answer to the question the OscarVault International (OVI) demo poses: **"Who authorized this action, through which agent, against what system, and can we prove the credentials have since expired?"**
