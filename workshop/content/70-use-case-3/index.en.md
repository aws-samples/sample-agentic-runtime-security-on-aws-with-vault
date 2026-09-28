---
title: 'Use Case 3: Privileged Action with CIBA'
weight: 70
---

## Demonstrates all five control objectives

Use Case 1 proved an agent can have an identity. Use Case 2 tied what it reads to who is asking. Use Case 3 is the one where money moves — so the agent has to ask a person first, and everything it is then allowed to do is decided by Vault on the request itself.

### Objectives Covered

| Objective | ID | How Use Case 3 Demonstrates It |
|---|---|---|
| Every agent has a verifiable identity | OBJ-1 | The delegated token carries both halves of the pair: `sub` is the human who approved on their phone, and `act.sub` is `uc3-actor` (RFC 8693 Token Exchange), which Vault resolves against the Agent Registry — so the request names *which agent* acted *for which person*, not just a caller |
| No standing privileges — JIT credentials only | OBJ-2 | The write credential is issued against the `uc3-refund-writer` database role with a 5-minute TTL and SELECT + INSERT + UPDATE only; the agent's `uc3-agent-ceiling` bounds the maximum it can ever hold, and a ceiling can only restrict, never grant |
| Actions tied to user intent | OBJ-3 | The refund does not proceed until the person approves it out-of-band through CIBA on their own device; the agent records the terms when it requests the approval and reads them back rather than re-asking the model, and a unique index lets one approval pay exactly once |
| Enforcement at the point of use | OBJ-4 | Vault narrows the token per request through `authorization_details` of `type: vault:path_access`, and Use Case 3 makes it **mandatory** (`optional_authorization_details=false`). The bypass test proves this layer on its own: a token whose RAR names a different path is denied even though the human baseline and the agent ceiling both permit the target |
| Audit trail correlates approval, authorization and write | OBJ-5 | One `request_id` (W3C `traceparent`) runs through the IVIA decision log, the Vault audit log and the RDS pgaudit log; the Vault record names the approving human in `auth.entity_id` and the agent in `actor_entity_name`, so a single Athena query returns one row spanning all three planes |

### What Use Case 3 Adds

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

