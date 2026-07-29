---
title: 'Five Control Objectives'
weight: 11
---

This workshop focuses on five control objectives for agentic systems:

1. **Verifiable identity** — every agent ties back to a cryptographically verifiable identity (workload ServiceAccount, user OAuth flow, or both) and is registered as a first-class identity in Vault's **Agent Registry** (`uc1-agent`, `agent-uc2`, `uc3-actor`), distinct from human users and traditional non-human identities.
2. **No standing privileges** — credentials are issued just-in-time, scoped to the request, and revoked when the work is done; each registered agent carries a `ceiling_policies` envelope that bounds the maximum it can ever hold when acting for a human.
3. **Actions tied to user intent** — privileged actions require demonstrable user consent (OAuth Authorization Code + PKCE for read access, CIBA out-of-band for writes).
4. **Enforcement at the point of use** — Vault is the decision point. The IVIA-issued OAuth JWT authorizes Vault directly via the `X-Vault-Token` header (the `ivia` OAuth resource-server profile), and Vault narrows the token per request through `authorization_details` of `type: vault:path_access`. Defense-in-depth still layers DB GRANTs + AWS IAM and Kubernetes NetworkPolicy underneath, so a compromise of any one layer doesn't bypass the others.
5. **Correlated audit evidence** — a shared `request_id` links the IVIA decision log (approval) and the RDS pgaudit log (the write), and the HashiCorp Vault audit log — which carries the agent-registry identity Vault resolved but deliberately logs no human subject or `request_id` — binds into the same forensic row by the exact credential path and the sub-second time-proximity of its authentication to that approval. Athena stitches all three planes into one row.

## Three use cases, in order

The workshop walks through three use cases in strict topological order — Use Case 3 is a strict superset of Use Case 1 + Use Case 2.

:::expand{header="Use Case 1 — Non-personalized read-only retrieval"}
A Strands agent runs in EKS with its own ServiceAccount (`uc1-retriever-sa`), registered in Vault's Agent Registry as `uc1-agent`. Vault's Kubernetes auth method validates the SA's JWT against the EKS OIDC provider, binds it to the `uc1` auth role (token TTL 1h, carrying the `uc1-readonly` policy), and issues just-in-time read-only Postgres credentials via `database/creds/uc1-readonly` (credential TTL 15 min) and scoped Bedrock STS credentials. Because Use Case 1 presents no OAuth actor, its `uc1-ceiling` is inert (registry identity only) — the `uc1-readonly` Kubernetes policy is the single enforcing layer. **Demonstrates Objectives 1, 2, 5.**
:::

:::expand{header="Use Case 2 — OAuth personalized read-only"}
The agent now requires a user JWT (Authorization Code + PKCE flow against IVIA). That OAuth JWT authorizes Vault **directly** via the `X-Vault-Token` header against the `ivia` OAuth resource-server profile — no `jwt_login`, no intermediate Vault token. This is an On-Behalf-Of flow: Vault intersects the human `sub` baseline with the `act.sub`=`agent-uc2` actor's `uc2-agent-ceiling` (two of three layers; the per-request RAR is optional for Use Case 2). INSERT attempts are rejected by DB GRANTs (Layer 2 enforcement). Egress to unapproved endpoints is blocked by Kubernetes NetworkPolicy (Layer 3). **Adds Objective 3.**
:::

:::expand{header="Use Case 3 — CIBA privileged + three-plane audit correlation"}
Privileged actions trigger a CIBA out-of-band approval flow. The resulting delegated JWT carries `act.sub`=`uc3-actor` (RFC 8693 Token Exchange) and `authorization_details` of `type: vault:path_access` (RFC 9396 RAR). Vault enforces the three-layer intersection natively: the human `sub` baseline ∩ the `uc3-agent-ceiling` (resolved from the actor) ∩ the **mandatory** per-request RAR. A bypass test confirms that a JWT whose RAR path differs is denied even when the entity's policy would permit the path. A single Athena query stitches the IVIA decision log, the Vault audit log, and the RDS pgaudit log into one forensic row — `request_id` links the approval to the write, and the Vault authentication binds in by credential path + time-proximity — and answers "Which user authorized this action, when, against what system, and was access revoked?" **Demonstrates all 5 Objectives.**
:::

