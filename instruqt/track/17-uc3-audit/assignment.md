---
slug: uc3-audit
id: zxzyfpzitbrl
type: challenge
title: Use Case 3 — Three-Plane Audit Correlation
teaser: One Athena query joins IVIA + Vault + pgaudit on a single request_id.
tabs:
- id: kxcrhdvvor9j
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
---

The **money shot** of the workshop. Each plane logs the same refund
independently:

- **IVIA** records *who approved* (user `sub`, CIBA binding message)
- **Vault** records *which agent authenticated* and the bound_claims it was
  validated against
- **PostgreSQL pgaudit** records *the INSERT that landed* on `banking.refunds`

The `audit_correlation` Athena VIEW stitches all three together on the shared
`request_id` (W3C `traceparent`) you propagated through every plane.

## Find your refund's request_id

The refund chat printed a `Request ID` line when the agent reported `Status:
approved`. If you didn't capture it, query the audit table for the most
recent refund event:

```bash
cd /root/workshop
REQ_ID=$(aws athena start-query-execution \
  --region "$AWS_REGION" --work-group workshop \
  --query-string "SELECT request_id FROM workshop_logs.audit_correlation
                  ORDER BY pgaudit_timestamp DESC LIMIT 1" \
  --query 'QueryExecutionId' --output text)
sleep 5
aws athena get-query-results --region "$AWS_REGION" \
  --query-execution-id "$REQ_ID" \
  --query 'ResultSet.Rows[1].Data[0].VarCharValue' --output text
```

## Run the correlation query

```bash
aws athena start-query-execution \
  --region "$AWS_REGION" --work-group workshop \
  --query-string "SELECT * FROM workshop_logs.audit_correlation
                  WHERE request_id = '<paste request_id here>'"
```

Wait for the query to succeed, then fetch the result. You should see ONE row
with:

| Column                            | Value                  |
| --------------------------------- | ---------------------- |
| `user_approved_sub`               | `jaime`                |
| `ciba_binding_message`            | `Approve refund …`     |
| `vault_principal`                 | `uc3-actor` / SA name  |
| `vault_bound_claim_may_act`       | `uc3-actor`            |
| `vault_bound_claim_rar_type`      | `refund_approval`      |
| `db_credential_ttl`               | `5m` (300s)            |
| `pgaudit_statement`               | `INSERT INTO banking.refunds …` |
| `request_id` present on all three planes | `<your traceparent>` |

That single row answers all five Workshop Objectives — verifiable identity,
no standing privileges, action tied to user intent, enforcement at the point
of use, and correlated audit evidence.
