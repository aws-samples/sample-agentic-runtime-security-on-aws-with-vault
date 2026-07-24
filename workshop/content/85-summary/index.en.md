---
title: 'Summary'
weight: 85
---

## What You Built — Vault's Native Agent Identity Model

This workshop deployed **HashiCorp Vault Enterprise 2.0.3** on EKS and wired it to enforce the five control objectives for agentic systems using Vault's **native AI agent primitives** — the first-class agent identity model HashiCorp ships in the product today. You configured the security primitives — Kubernetes auth, the OAuth resource server, the Agent Registry, ceiling-policy intersection, and Vault-side per-request Rich Authorization Requests (RAR) — at the layer where enforcement actually happens.

### Vault's Native AI Agent Support Is Deployed Here

HashiCorp's [native AI agent support in Vault](https://www.hashicorp.com/en/blog/announcing-native-ai-agent-support-in-hashicorp-vault) is a released Enterprise capability, and this workshop runs it. Three native primitives carry the authorization model:

- **Agent Registry** — each agent is registered as a first-class identity (`uc1-agent`, `agent-uc2`, `uc3-actor`), distinct from human users and traditional non-human identities, with a `ceiling_policies` envelope on the registration.
- **OAuth resource server** — the IVIA-issued OAuth JWT authorizes the Vault request **directly** via the `X-Vault-Token` header. There is no `jwt_login`, no intermediate Vault token, and the legacy `jwt` auth backend has been **retired** entirely.
- **Vault-side per-request RAR** — `authorization_details` of `type: vault:path_access` narrow a token to the exact path and capabilities of a single request. **Vault itself** is the interpreter and the decision point.

The table below maps each workshop use case to the native Vault capability it deploys:

| What you deployed in this workshop | Vault native agent capability |
|---|---|
| **Use Case 1** — Vault Kubernetes auth binds the agent ServiceAccount to the `uc1-readonly` policy with JIT credentials (TTL 15m); the agent is registered as `uc1-agent` | **Agent Registry** — the agent holds a first-class registry identity. Because Use Case 1 presents no OAuth actor, its `uc1-ceiling` is inert (informational only); the `uc1-readonly` Kubernetes policy is the enforcement floor |
| **Use Case 2** — IVIA OAuth Authorization Code + PKCE → the user's OAuth JWT authorizes Vault directly via `X-Vault-Token` against the `ivia` resource-server profile | **OAuth resource server + On-Behalf-Of (OBO) delegation** — the human `sub` contributes the human baseline, the `act.sub`=`agent-uc2` actor contributes the `uc2-agent-ceiling`, tracked in the Agent Registry |
| **Use Case 3** — the delegated CIBA JWT carries `act.sub`=`uc3-actor` and `authorization_details` of `type: vault:path_access`, enforced by Vault per request | **Ceiling intersection + mandatory per-request RAR** — Vault narrows the token to the exact path/capability for that one refund and denies any request whose RAR path differs |
| **Use Case 3** — three-plane audit correlation (IVIA + Vault + RDS pgaudit joined by `request_id`) | **End-to-end tracing and attribution** — audit events carry the agent-registry identity; correlation reads "agent X acting for human Y" |
| All use cases — no standing privileges; credentials expire with the token lifecycle | **Ephemeral per-request authorization** — permissions bind to the token's lifecycle; when the token expires, the agent cannot take further action |

### How the Native Layers Map to the Five Control Objectives

Vault's native model enforces a **policy intersection** — a request is permitted only if it falls within the overlap of every layer that applies to that use case. **The number of enforcing layers differs by use case**, because the identity each agent presents to Vault differs:

- **Use Case 1 — one enforcing layer.** The agent authenticates with its ServiceAccount JWT through the Kubernetes auth method and resolves to the `uc1-readonly` policy. It carries a registry identity (`uc1-agent`), but with no OAuth actor its `uc1-ceiling` does not self-apply — so the Kubernetes policy floor is the single enforcing layer. → *Objective 1: verifiable identity; Objective 2: no standing privileges.*
- **Use Case 2 and Use Case 3 — three enforcing layers.** Both are On-Behalf-Of flows. Vault intersects **(a)** the human owner's baseline (resolved from the OAuth `sub` entity → *Objective 3: actions tied to user intent*), **(b)** the agent's `ceiling_policies` (`uc2-agent-ceiling` / `uc3-agent-ceiling`, resolved from the `act.sub` actor → *Objective 2: no standing privileges*), and **(c)** the per-request `vault:path_access` RAR (→ *Objective 4: enforcement at the point of use*). A request succeeds only if all three permit; the ceiling can only *restrict*, never grant. Use Case 3 makes the RAR **mandatory** (`optional_authorization_details=false`); Use Case 2 makes it optional.

Objective 5 (correlated audit evidence) maps to Vault's native end-to-end tracing: audit events carry the agent-registry identity and join the IVIA and RDS pgaudit planes on `request_id`.

### Key Takeaway

Agent identity, the ceiling envelope, and per-request scoping are **native Vault capabilities you configured and enforced today** — not hand-rolled approximations and not a roadmap item. Vault is the sole enforcement point: IVIA remains the issuer, delegation, and CIBA-consent authority, and every authorization decision is made natively by Vault against the registered agent's ceiling and the request's `vault:path_access` RAR. Teams adopting this model implement exactly the pattern you deployed here.
