# Audit Correlation Queries

> **The single audit-correlation reference for this workshop.** Every downstream phase that emits, queries, or joins audit data MUST link to this document — do not fork copies.

## Purpose

The Agentic Runtime Security workshop uses **W3C Trace Context** (`traceparent` HTTP header per [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110) / [OpenTelemetry](https://www.w3.org/TR/trace-context/) standard) as the cross-plane correlation key. Every request entering the agent stack carries a 16-byte `trace-id` that propagates through the agent, identity, secrets, data, and AWS API planes — letting attendees JOIN five log streams on a single column to reconstruct "what did this request do, end-to-end" in the UC3 audit-correlation exercise (Phase 6).

Why `traceparent` over alternatives:

- **Custom `X-Trace-Id`** — no upstream tooling; every plane needs a custom adapter.
- **AWS `X-Amzn-Trace-Id`** — AWS-native, but Vault and IVIA don't speak it.
- **W3C `traceparent`** — Strands' OTel tracing emits and propagates it natively; Vault's audit device records it in `request.id`; IVIA's decision log records it via `X-Request-Id` (one-line normalization in the agent). Cross-vendor; bridges to AWS X-Ray via ADOT when needed.

**Decision logged:** [02-CONTEXT.md](../../.planning/phases/02-foundation-infrastructure/02-CONTEXT.md) "Audit-correlation contract".

## trace-id Generation Point

The **agent** generates `traceparent` if absent on inbound, via the OTel SDK helper that ships with [Strands tracing](https://github.com/strands-agents/sdk-python) — Strands already wraps every Bedrock invocation in a span, and the span's `trace-id` is the one that flows downstream.

**Trade-off considered (Open Question 1):** ALB-as-generator vs agent-as-generator. ALB-as-generator would set the header at the edge, but ALB can't propagate it into Strands' OTel context — Strands would still have to bind the inbound header to its span, so we save nothing. Agent is the single generation point; ALB does not touch the header.

## Propagation Path

Every hop the request makes after entering the agent:

1. **Agent → Bedrock LLM (Converse)** — Strands' tracing forwards `traceparent`; the span lands in `/workshop/agent-trace`.
2. **Agent → Vault (hvac)** — agent sets `X-Vault-Request-Id: <trace-id>`. Vault's audit device records it in `request.id` per [Vault audit conventions](https://developer.hashicorp.com/vault/docs/audit).
3. **Agent → IVIA** — agent sets `X-Request-Id: <trace-id>`; IVIA's decision log records it in the request-id column.
4. **Agent → RDS (psycopg)** — agent passes `application_name=<trace-id>` in the connection's `options`. pgaudit emits it on every `LOG:` line in `/aws/rds/instance/<id>/postgresql`.
5. **Agent / Vault → AWS APIs (boto3 / Vault AWS secrets engine)** — AWS APIs don't carry `traceparent`. CloudTrail records principal + event time only; we bridge to CloudTrail via the **composite-key** strategy below.

## Log Sources

| Plane | Source | CloudWatch Log Group | Indexing field |
|-------|--------|----------------------|----------------|
| User identity | IBM Verify Identity Access (decision logs) | `/workshop/ivia-decision` | `X-Request-Id` (= traceparent's trace-id) |
| Workload identity / credential broker | HashiCorp Vault (audit device) | `/workshop/vault-audit` | `request.id` field (= traceparent's trace-id) |
| Agent runtime | Strands Agent (OTel span exporter) | `/workshop/agent-trace` | `traceparent` (full header) |
| AWS plane | CloudTrail (default trail) | (default trail S3 bucket) | `eventID` + `userIdentity.arn` (NO traceparent) |
| Database | RDS PostgreSQL (pgaudit) | `/aws/rds/instance/<id>/postgresql` | `application_name` (set by app to traceparent's trace-id) |

The first three log groups are **pre-created in Phase 2** by the [`audit` module](../modules/audit/) (KMS-encrypted with the workshop CMK, 7-day default retention). The RDS log group is auto-created by RDS on first export. CloudTrail uses the default trail — see Phase 1's `30-foundational/index.en.md` for the trail-bucket lookup.

## Composite Join Strategy

CloudTrail breaks the pure-trace_id join: it has no field to carry `traceparent`, and AWS service code does not propagate it through service-internal calls. Trying to JOIN agent_trace ↔ cloudtrail on a single column will always miss rows.

**Composite key** = `(trace-id WHERE present) ∪ (principal + ±5s timestamp window)`:

- **Primary join**: `trace-id` (16-byte hex extracted from `traceparent`). Present in agent_trace, vault_audit, ivia_decision, RDS pgaudit — these four planes JOIN cleanly.
- **CloudTrail bridge**: LEFT JOIN on `(userIdentity.arn = vault_audit.client_principal) AND (cloudtrail.eventTime BETWEEN vault_audit.timestamp - INTERVAL '5' SECOND AND vault_audit.timestamp + INTERVAL '5' SECOND)`. The 5s window absorbs IAM eventual-consistency latency; the principal absorbs the missing trace-id.

**Why ±5s?** Vault dynamic-credential issuance to AWS API call typically lands in <1s; 5s is a safety margin tested against the workshop's UC3 flow. Tighten in production; the workshop teaches the pattern.

## Example Athena Query Template

This template runs against the Glue tables Phase 6 populates (the table definitions are not in Phase 2 — see "Glue Database / Athena Workgroup" below). Replace `<TRACE_ID_FROM_UC3_REQUEST>` with the trace-id printed by the UC3 demo agent.

```sql
-- Source: workshop_logs (Glue catalog database, Athena workgroup 'workshop')
-- Phase 2 ships the database + workgroup empty; Phase 6 adds the per-source tables.
-- This query is the load-bearing UC3 audit-correlation deliverable.

WITH agent_events AS (
  SELECT
    regexp_extract(message, 'traceparent: 00-([0-9a-f]{32})-', 1) AS trace_id,
    timestamp                                                       AS event_time,
    json_extract_scalar(message, '$.attributes.span_name')          AS span_name,
    message                                                         AS raw
  FROM workshop_logs.agent_trace
  WHERE timestamp BETWEEN current_timestamp - interval '1' hour AND current_timestamp
),
vault_events AS (
  SELECT
    json_extract_scalar(message, '$.request.id')                    AS trace_id,
    json_extract_scalar(message, '$.auth.client_token_accessor')    AS principal,
    timestamp                                                       AS event_time,
    json_extract_scalar(message, '$.request.path')                  AS vault_path,
    json_extract_scalar(message, '$.request.operation')             AS vault_op
  FROM workshop_logs.vault_audit
),
ivia_events AS (
  SELECT
    json_extract_scalar(message, '$.requestId')                     AS trace_id,
    json_extract_scalar(message, '$.subject')                       AS subject,
    timestamp                                                       AS event_time,
    json_extract_scalar(message, '$.decision')                      AS decision
  FROM workshop_logs.ivia_decision
),
cloudtrail_events AS (
  SELECT
    eventid,
    eventname,
    eventtime                                                       AS event_time,
    useridentity.arn                                                AS user_arn
  FROM workshop_logs.cloudtrail
  WHERE eventsource = 'sts.amazonaws.com'
     OR eventsource = 'rds-data.amazonaws.com'
     OR eventsource = 'bedrock-runtime.amazonaws.com'
)
SELECT
  a.trace_id,
  a.event_time     AS agent_time,
  a.span_name,
  i.subject        AS user_subject,
  i.decision       AS ivia_decision,
  v.vault_path,
  v.vault_op,
  ct.eventname     AS aws_api,
  ct.user_arn      AS aws_caller
FROM agent_events a
JOIN vault_events v ON a.trace_id = v.trace_id
JOIN ivia_events i  ON a.trace_id = i.trace_id
LEFT JOIN cloudtrail_events ct
  ON  ct.user_arn   = v.principal
  AND ct.event_time BETWEEN v.event_time - interval '5' second
                        AND v.event_time + interval '5' second
WHERE a.trace_id = '<TRACE_ID_FROM_UC3_REQUEST>'
ORDER BY a.event_time;
```

The template demonstrates **all 5 control objectives** in one query result: every row shows the user identity (IVIA), the workload identity (Vault path), the agent decision (span_name), the policy enforcement (Vault op), and the resulting AWS API call (CloudTrail) — correlated on a single trace-id.

## Glue Database / Athena Workgroup

Phase 2 ships the audit query infrastructure **empty**:

- **Glue catalog database `workshop_logs`** — created by `infrastructure/modules/audit/` ([`aws_glue_catalog_database.workshop_logs`](../modules/audit/main.tf)).
- **Athena workgroup `workshop`** — created by the same module; KMS-encrypted query results in `s3://workshop-athena-<random>/results/`.

Per [Open Question 4 in 02-RESEARCH.md](../../.planning/phases/02-foundation-infrastructure/02-RESEARCH.md): we deliberately defer the per-source `aws_glue_catalog_table` definitions to Phase 6 because each plane's log structure (Vault audit JSON shape, IVIA decision-log shape, CloudTrail event JSON, pgaudit text format) only finalizes when those planes are deployed and emitting real data. Adding tables in Phase 2 would require schema rewrites in Phase 3 (Vault) and Phase 6 (UC3 + CloudTrail) — better to add them once when the shape is known.

## Forward References

| Phase | What it adds to this audit story |
|-------|-----------------------------------|
| Phase 3 — Vault + IVIA + agent infra | fluent-bit DaemonSet shipping Vault audit + IVIA decision logs into the pre-created `/workshop/vault-audit` and `/workshop/ivia-decision` log groups by ARN. |
| Phase 4 — UC1 / UC2 agents | OpenTelemetry SDK config emitting agent spans into `/workshop/agent-trace` with `traceparent` propagation to Vault + Bedrock. |
| Phase 5 — UC3 agent + observability | The end-to-end UC3 trace that this query template targets — privileged R/W flow with full identity + decision + AWS API correlation. |
| Phase 6 — Audit correlation deep-dive | Adds the `aws_glue_catalog_table` resources in `workshop_logs` and ships the actual cross-plane query in workshop content (`30-foundational/audit-correlation/`). |

## Trace-id Propagation Diagram

```text
                     ┌────────────────────────────────────────────────┐
                     │                                                │
                     │    User browser / curl  (no traceparent yet)   │
                     │                                                │
                     └───────────────────────┬────────────────────────┘
                                             │ POST /chat
                                             ▼
                     ┌────────────────────────────────────────────────┐
                     │   Agent (Strands)  ──── generates traceparent  │
                     │                          via OTel SDK           │
                     │   trace-id = 4a3b2c1d...                       │
                     └─┬──────────────┬─────────────┬─────────────────┘
                       │              │             │
              X-Vault-Request-Id      │      X-Request-Id
              + hvac call             │      + IVIA call
                       │              │             │
                       ▼              ▼             ▼
              ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐
              │   Vault     │  │   Bedrock   │  │      IVIA       │
              │ audit log   │  │  (Strands   │  │  decision log   │
              │ request.id  │  │  span)      │  │  X-Request-Id   │
              └──────┬──────┘  └──────┬──────┘  └─────────────────┘
                     │                │
                     │ Vault AWS      │ (no API; pure LLM call)
                     │ secrets engine │
                     ▼                │
              ┌─────────────┐         │
              │   AWS STS   │         │
              │ AssumeRole  │         │
              └──────┬──────┘         │
                     │                │
                     ▼                ▼
              ┌─────────────────────────────────┐
              │   CloudTrail (no traceparent)   │
              │   bridge via principal + ±5s    │
              └─────────────────────────────────┘

5 streams → JOIN on trace-id (4 planes) + composite-key (CloudTrail bridge)
                              ↓
                  workshop_logs.* via Athena workgroup 'workshop'
                              ↓
                       UC3 audit-correlation query
```

## See Also

- [`infrastructure/modules/audit/`](../modules/audit/) — terraform that ships the CMK + log groups + Glue + Athena.
- [`.planning/phases/02-foundation-infrastructure/02-CONTEXT.md`](../../.planning/phases/02-foundation-infrastructure/02-CONTEXT.md) — the workshop-level decision rationale.
- [`.planning/phases/02-foundation-infrastructure/02-RESEARCH.md`](../../.planning/phases/02-foundation-infrastructure/02-RESEARCH.md) — Patterns 6-7, the workshop CMK key policy snippet, and the Athena query template prototype.
- [W3C Trace Context spec](https://www.w3.org/TR/trace-context/) — the canonical reference for `traceparent`.
