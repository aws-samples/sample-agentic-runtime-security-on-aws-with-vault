---
title: 'Five Control Objectives'
weight: 11
---

This workshop focuses on five control objectives for agentic systems:

1. **Verifiable identity** — every agent ties back to a cryptographically verifiable identity (workload SA, user OAuth flow, or both).
2. **No standing privileges** — credentials are issued just-in-time, scoped to the request, and revoked when the work is done.
3. **Actions tied to user intent** — privileged actions require demonstrable user consent (OAuth Authorization Code + PKCE for read access, CIBA out-of-band for writes).
4. **Enforcement at the point of use** — three layers of defense (Vault policies, DB GRANTs + AWS IAM, Kubernetes NetworkPolicy) so a compromise of any one layer doesn't bypass the others.
5. **Correlated audit evidence** — a single propagated `request_id` joins IVIA decision logs, HashiCorp Vault audit logs, and RDS pgaudit logs in Athena.

## Three use cases, in order

The workshop walks through three use cases in strict topological order — Use Case 3 is a strict superset of Use Case 1 + Use Case 2.

:::expand{header="Use Case 1 — Non-personalized read-only retrieval"}
A Strands agent runs in EKS with its own ServiceAccount (`uc1-retriever-sa`). Vault's Kubernetes auth method validates the SA's JWT against the EKS OIDC provider, binds it to the `uc1` auth role (token TTL 1h, carrying the `uc1-readonly` policy), and issues just-in-time read-only Postgres credentials via `database/creds/uc1-readonly` (credential TTL 15 min) and scoped Bedrock STS credentials. **Demonstrates Objectives 1, 2, 5.**
:::

:::expand{header="Use Case 2 — OAuth personalized read-only"}
The agent now requires a user JWT (Authorization Code + PKCE flow against IVIA). The user JWT is exchanged via Vault's `jwt` auth method (`bound_audiences=["agent-uc2"]`) for per-user-scoped database credentials. INSERT attempts are rejected by DB GRANTs (Layer 2 enforcement). Egress to unapproved endpoints is blocked by Kubernetes NetworkPolicy (Layer 3). **Adds Objective 3.**
:::

:::expand{header="Use Case 3 — CIBA privileged + three-plane audit correlation"}
Privileged actions trigger a CIBA out-of-band approval flow. The resulting JWT carries `may_act` (RFC 8693 Token Exchange) and `authorization_details` (RFC 9396 RAR) claims, enforced by Vault `bound_claims`. A bypass test confirms that forged `may_act` claims are rejected. A single Athena query joins IVIA decision logs + Vault audit logs + RDS pgaudit logs by `request_id` and answers "Which user authorized this action, when, against what system, and was access revoked?" **Demonstrates all 5 Objectives.**
:::

