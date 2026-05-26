---
title: 'Use Case 3: Privileged Action with CIBA'
weight: 70
---

## What Use Case 3 Adds

Use Case 3 extends the workshop stack with four interlocking controls that work together to authorize, enforce, and audit a privileged refund write:

| Capability | Standard (RFC / Spec) | Enforcement Point |
|---|---|---|
| Out-of-band user approval | CIBA (OpenID Connect CIBA) | IBM Verify (IVIA) |
| Delegation proof on the token | Token Exchange `may_act` (RFC 8693) | Vault `bound_claims` |
| Rich Authorization Request | `authorization_details` type (RFC 9396 RAR) | Vault `bound_claims` |
| Time-boxed write credential | 5-minute TTL, SELECT+INSERT+UPDATE only | Vault DB role `uc3-refund-writer` |

A single `request_id` (W3C `traceparent`) propagates through every plane and becomes the JOIN key in the three-plane Athena audit correlation query — the workshop's pedagogical money shot.

## Request Flow

The diagram below shows how `request_id` moves from the agent through CIBA approval, token exchange, Vault JWT auth, the database write, and all three audit planes.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {
  'primaryColor': '#d0e2ff',
  'primaryTextColor': '#161616',
  'primaryBorderColor': '#0f62fe',
  'lineColor': '#0f62fe',
  'secondaryColor': '#bae6ff',
  'tertiaryColor': '#f4f4f4',
  'noteBkgColor': '#e8daff',
  'noteTextColor': '#161616',
  'noteBorderColor': '#8a3ffc',
  'actorBkg': '#d0e2ff',
  'actorBorder': '#0f62fe',
  'actorTextColor': '#161616',
  'signalColor': '#161616',
  'signalTextColor': '#161616',
  'labelBoxBkgColor': '#d0e2ff',
  'labelBoxBorderColor': '#0f62fe',
  'labelTextColor': '#161616',
  'loopTextColor': '#161616',
  'activationBorderColor': '#0f62fe',
  'activationBkgColor': '#edf5ff',
  'sequenceNumberColor': '#ffffff'
}}}%%
sequenceDiagram
    autonumber
    participant Agent as Use Case 3 Agent<br/>(banking-app)
    participant IVIA as IBM Verify<br/>(IVIA / CIBA)
    participant User as Authorized User<br/>(browser approval)
    participant TE as Token Exchange<br/>(IVIA RFC 8693)
    participant Vault as HashiCorp Vault<br/>(JWT auth + DB)
    participant RDS as PostgreSQL RDS<br/>(banking.refunds)
    participant CW as CloudWatch<br/>(agent-trace)
    participant S3 as S3 Log Bucket
    participant Athena as Athena<br/>(audit_correlation VIEW)

    Agent->>IVIA: POST /oauth2/ciba<br/>binding_message=request_id<br/>(direct to OIDC Provider ClusterIP)
    IVIA-->>Agent: auth_req_id
    IVIA->>IVIA: notifyuser rule (InternalAuthenticator)<br/>sets consent URL on WRP
    Note over IVIA,User: Consent URL: http://wrp-alb/isvaop/oauth2/ciba_user_authorize/{id}<br/>Browser flow goes through WRP — agent shows URL in chat
    Agent->>User: Display consent URL
    User->>IVIA: Approve via WRP consent page<br/>(WRP handles login + forwards authenticated session)
    Agent->>IVIA: Poll /token (grant_type=ciba)<br/>until approval (direct to OIDC Provider ClusterIP)
    IVIA-->>Agent: subject_token (access_token)
    Agent->>TE: POST /token (grant_type=token-exchange)<br/>subject_token=user token<br/>(auth as uc3-actor client, HTTP Basic — no actor_token)
    TE-->>Agent: delegated JWT with may_act + authorization_details
    Note over Agent,TE: isvaop_pretoken rule injects may_act.sub=uc3-actor<br/>JWT carries request_id + authorization_details.type=refund_approval
    Agent->>Vault: POST auth/jwt/login role=uc3-jwt jwt=delegated_JWT
    Note over Vault: bound_claims: /may_act/sub=* (glob, any actor sub passes)<br/>authorization_details[0].type=refund_approval is claim_mapping metadata only — not enforced
    Vault-->>Agent: Vault token
    Agent->>Vault: GET database/creds/uc3-refund-writer (TTL=5m)
    Vault-->>Agent: username + password (JIT, time-boxed)
    Agent->>RDS: INSERT INTO banking.refunds (request_id, ...) VALUES (...)
    RDS-->>Agent: OK
    Agent->>CW: Emit trace log (request_id, user_sub, action, vault_role)
    CW->>S3: fluent-bit exports logs → S3 log bucket
    S3->>Athena: Glue crawler → audit_correlation VIEW
    Note over Athena: SELECT * FROM audit_correlation WHERE request_id = '...'<br/>→ one row answers all 5 objectives
```
