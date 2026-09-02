---
title: 'Use Case 3: Privileged Action with CIBA'
weight: 70
---

## What Use Case 3 Adds

![Vault Enterprise native OBO — Agent Registry resolves the agent from act.sub; the effective grant is the human baseline ∩ agent ceiling ∩ per-request vault:path_access RAR](/static/images/agent-registry-flow.png)

Use Case 3 extends the workshop stack with four interlocking controls that work together to authorize, enforce, and audit a privileged refund write:

| Capability | Standard (RFC / Spec) | Enforcement Point |
|---|---|---|
| Out-of-band user approval | CIBA (OpenID Connect CIBA) | IBM Verify (IVIA) |
| Delegation proof on the token | Token Exchange `act` (RFC 8693) | Vault Agent Registry (`act.sub`) |
| Rich Authorization Request | `authorization_details` type (RFC 9396 RAR) | Vault `vault:path_access` RAR |
| Time-boxed write credential | 5-minute TTL, SELECT+INSERT+UPDATE only | Vault DB role `uc3-refund-writer` |

A single `request_id` (W3C `traceparent`) propagates through every plane and becomes the JOIN key in the three-plane Athena audit correlation query — the workshop's pedagogical money shot.

:::alert{header="What Vault cryptographically enforces vs. what the audit proves" type="info"}
Vault **enforces** three things on the exchanged token before it issues any database credential: the **identity** (`sub` = the human who approved via CIBA), the **delegation** (`act.sub` = `uc3-actor`, RFC 8693 — *which agent* acts, resolved against the Agent Registry), and the **per-request RAR** (`vault:path_access` = the exact path being requested, RFC 9396). The **amount/currency** is **not** a token claim and is **not** shown on the phone — IBM Verify (ISVAOP 25.10) does not surface the consent-time RAR to any mapping rule at the token-exchange stage, and Vault's `vault:path_access` RAR is a path match that cannot range-check a number anyway. The terms are bound instead by the agent recording them when it requests the approval and reading them back rather than re-asking the model, and by a unique index that lets one approval pay exactly once. The `audit_correlation` row then ties the approval, the Vault authorization and the write together on one `request_id`. What the phone tap proves, precisely, is user presence — see the [CIBA Approval Flow](71-ciba-approval-flow/) page and `infrastructure/modules/verify_access/README.md`, "UC3 RAR enforcement model."
:::

