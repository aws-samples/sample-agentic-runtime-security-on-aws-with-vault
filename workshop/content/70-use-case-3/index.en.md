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
%%{init: {"theme": "base", "themeVariables": {"primaryColor": "#0f62fe", "primaryTextColor": "#161616", "primaryBorderColor": "#0043ce", "lineColor": "#525252", "secondaryColor": "#f4f4f4", "tertiaryColor": "#e0e0e0", "noteBkgColor": "#d9fbfb", "noteTextColor": "#161616", "noteBorderColor": "#3ddbd9"}}}%%
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

    Agent->>IVIA: POST /bc-authorize<br/>binding_message=request_id<br/>(direct to OIDC Provider ClusterIP)
    IVIA-->>Agent: auth_req_id
    IVIA->>IVIA: notifyuser rule (InternalAuthenticator)<br/>sets consent URL on WRP
    Note over IVIA,User: Consent URL: http://wrp-alb/isvaop/oauth2/ciba_user_authorize/{id}<br/>Browser flow goes through WRP — agent shows URL in chat
    Agent->>User: Display consent URL
    User->>IVIA: Approve via WRP consent page<br/>(WRP handles login + forwards authenticated session)
    Agent->>IVIA: Poll /token (grant_type=ciba)<br/>until approval (direct to OIDC Provider ClusterIP)
    IVIA-->>Agent: subject_token (access_token)
    Agent->>TE: POST /token (grant_type=urn:ietf:params:oauth:grant-type:token-exchange)<br/>actor_token=SA JWT, subject_token=user token
    TE-->>Agent: delegated JWT with may_act + authorization_details
    Note over Agent,TE: JWT carries request_id, may_act.sub, authorization_details.type=refund_approval
    Agent->>Vault: POST auth/jwt/login role=uc3-jwt jwt=delegated_JWT
    Note over Vault: bound_claims: may_act.sub=service-account:agent-uc3<br/>authorization_details[0].type=refund_approval
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

## Sub-modules

1. **[CIBA Out-of-Band Approval](71-ciba-approval-flow/)** — How IVIA handles the backchannel approval and token exchange
2. **[Vault Bound Claims Enforcement](72-configure-bound-claims/)** — How `bound_claims` enforces `may_act` and `authorization_details`
3. **[The Bypass Test](73-bypass-test/)** — Forged JWT rejection proof (run `verify-uc3.sh --bypass`)
4. **[Three-Plane Audit Correlation](74-three-plane-audit/)** — The Athena query that joins all three audit planes by `request_id`
