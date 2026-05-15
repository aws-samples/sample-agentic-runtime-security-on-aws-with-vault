---
title: 'Summary'
weight: 85
---

:::alert{header="Content pending" type="info"}
This module will recap the five control objectives against what attendees actually deployed, with concrete pointers back to the configuration that satisfies each objective and a takeaway pattern attendees can lift into their own agentic systems.
:::

## What You Built — and Where the Industry Is Heading

This workshop deployed **HashiCorp Vault 2.0** on EKS and wired it, by hand, to enforce the five control objectives for agentic systems. That hands-on approach was deliberate: you now understand the security primitives — Kubernetes auth, `jwt` auth with `bound_claims`, dynamic secrets with TTL ceilings, RFC 9396 Rich Authorization Requests (RAR), and three-plane audit correlation — at the layer where enforcement actually happens.

### Vault's Native AI Agent Support (May 2026)

In May 2026 HashiCorp [announced native AI agent support in Vault](https://www.hashicorp.com/en/blog/announcing-native-ai-agent-support-in-hashicorp-vault), introducing first-class primitives for exactly the patterns you implemented in this workshop. The new capabilities — currently in early access with public beta planned for summer 2026 — formalize what you built manually into a unified authorization model.

The table below maps our workshop's use cases to Vault's new native agent features:

| What you built in this workshop | Vault native agent equivalent |
|---|---|
| **Use Case 1** — Vault K8s auth binds agent SA to `uc1-readonly` role with JIT credentials (TTL 15m) | **Agent Registry** — register and manage agent identities separately from human and traditional NHI identities, with baseline access policies |
| **Use Case 2** — IVIA OAuth + PKCE → Vault `jwt` auth vends per-user-scoped credentials | **On-Behalf-Of (OBO) delegation** — agents act with human user authority; delegation and consent explicitly tracked in the agent registry |
| **Use Case 3** — `may_act` (RFC 8693) + `authorization_details` (RFC 9396 RAR) enforced by Vault `bound_claims`; TTL 5m R/W ceiling | **4-layer policy intersection** — human policies, baseline access, ceiling policies (absolute blast radius), and per-request `authorization_details` embedded in the JWT |
| **Use Case 3** — three-plane audit correlation (IVIA + Vault + CloudTrail joined by `request_id`) | **End-to-end tracing and attribution** — per-agent action tracking with clear attribution for actions performed on behalf of users |
| All use cases — no standing privileges; credentials expire with the token lifecycle | **Ephemeral per-request authorization** — permissions bound to the token's lifecycle; when the token expires, the agent cannot take further action |

### The Five Control Objectives Map to Vault's Four-Layer Model

Vault's native agent authorization uses a **policy intersection model** — an action is only permitted if it falls within the overlap of all four policy layers:

1. **Human policies** — does the delegating human have access? → *Objective 3: actions tied to user intent*
2. **Baseline access policies** — does the agent itself have base access? → *Objective 1: verifiable identity*
3. **Ceiling policies** — is the action within the maximum blast radius? → *Objective 2: no standing privileges*
4. **Authorization details** — is the per-request context satisfied? → *Objective 4: enforcement at point of use*

Objective 5 (correlated audit evidence) maps to Vault's new end-to-end tracing capability.

### Key Takeaway

What you configured manually through Vault `jwt` auth roles, `bound_claims`, dynamic secret TTLs, and Athena audit queries will become a single, integrated authorization model in Vault. The security primitives and the control objectives stay the same — the operational surface shrinks. When Vault's native agent support reaches GA, teams adopting it will be implementing the same patterns you practiced today, with less wiring.
