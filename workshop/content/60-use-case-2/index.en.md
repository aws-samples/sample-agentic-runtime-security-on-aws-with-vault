---
title: 'Use Case 2 — OAuth Personalized Read-only'
weight: 60
---

## Overview

Use Case 2 builds directly on Use Case 1 by adding **user identity** to the credential flow. In Use Case 1 the agent acts as a workload — it has no knowledge of who sent the query, and all users receive the same data. In Use Case 2 the banking app authenticates the user through IBM Verify Identity Access (IVIA) using the OAuth Authorization Code + PKCE flow, and that user identity propagates all the way to the database through short-lived, per-user-scoped Vault credentials. The agent now knows *who* is asking, and the database enforces data isolation at the row level.

This use case adds **Objective 3 — actions tied to user intent** on top of the workload identity and JIT credential foundations established in Use Case 1.

## Objectives Covered

| Objective | ID | How Use Case 2 Demonstrates It |
|---|---|---|
| Every agent has a verifiable identity | OBJ-1 | The MCP Server authenticates to Vault with its own Kubernetes ServiceAccount (`uc2-mcp-server-sa`) — only that SA in the `banking-app` namespace can obtain a `uc2-personal` Vault token, and that token's single capability is revoking the credentials it issued |
| No standing privileges — JIT credentials only | OBJ-2 | Per-user Postgres credentials are issued dynamically via Vault's database secrets engine with a 15-minute TTL; no credential is stored on disk or in environment variables at rest |
| Actions tied to user intent | OBJ-3 | The user's IVIA-issued access token carries both the `sub` claim (the human) and the `act.sub` claim (the acting agent); the MCP Server presents that token directly to Vault as `X-Vault-Token`; Vault's OAuth resource server validates it against IVIA's JWKS, resolves the agent through the Agent Registry, and issues per-user-scoped DB credentials; the database enforces Row-Level Security so each user sees only their own rows |
| Enforcement at the point of use | ENFC-02 | The database credential is issued against `uc2-personal-readonly`, whose Postgres GRANTs exclude INSERT — so even if the Vault policy were widened, the DB GRANT layer still rejects writes |
| Enforcement at the point of use | ENFC-03 | Kubernetes NetworkPolicy restricts MCP Server egress to Vault, RDS, and DNS only — external HTTP calls are blocked at the network layer |
| Audit trail ties credential issuance to user identity | OBJ-5 | The Vault audit log records both the OAuth resource server authorization (with the user's `sub` claim) and the subsequent database/creds issuance — providing a correlated audit trail from user identity to data access |

## Services Deployed

| Service | Runtime | Port | Role |
|---|---|---|---|
| Banking UI | SvelteKit (Node 22) | 5173 | Browser OAuth flow, JWT custody, Agent API calls |
| Banking Agent | Python / Strands SDK | 3002 | LLM orchestration, tool routing via MCP |
| MCP Server | Node.js / Express | 3001 | Vault OAuth resource server (X-Vault-Token), JIT DB credentials, query execution |

All three pods run in the `banking-app` namespace. Separate ALB Ingress exposes the Banking UI externally. Agent and MCP Server are ClusterIP-only — no external exposure.

## What You Will Learn

- OAuth Authorization Code + PKCE flow: `code_verifier`, `code_challenge`, S256 hashing
- How IVIA acts as the identity provider and issues JWTs with user `sub`, `aud`, and `azp` claims
- How Vault's OAuth resource server profile validates an IVIA access token presented directly as `X-Vault-Token` — no `auth/jwt/login` round-trip, no intermediate Vault token, and no confidential client secret at the Vault layer
- How per-user Postgres credentials are scoped using Vault's database secrets engine and PostgreSQL Row-Level Security
- How the MCP Server (not the agent) holds the credential-fetching responsibility — the agent never sees a DB credential
- How Layer 2 (DB GRANTs) and Layer 3 (NetworkPolicy) enforcement work in combination as defense-in-depth
- How the MCP Server revokes each database credential itself, using its own Kubernetes-auth Vault token, the moment the query it was issued for returns — and how that revoke removes the Postgres role immediately rather than at lease expiry
- How the Vault audit log links a `sub` claim to a `database/creds` issuance — OBJ-5 audit correlation

## Prerequisites

You must have completed the **Deploy Foundation** module before starting here. Specifically:

- `vault` — Vault HA cluster running and initialized
- `vault_config` — Kubernetes auth backend, OAuth resource server profile `ivia` (pointing to IVIA OIDC discovery), `uc2-personal` policy + `uc2-agent-ceiling`, `uc2` Kubernetes auth role, `agent-uc2` Agent Registry registration, and `uc2-personal-readonly` database credentials role configured
- `verify_access` — IVIA OIDC provider deployed with `agent-uc2` OAuth client (PKCE required, authorization_code grant) configured declaratively via config.yaml
- `uc2_app` — Banking UI, Banking Agent, and MCP Server deployed via local Terraform (`terraform -chdir=infrastructure apply`)
- `seed-banking-db.sh` — Banking schema, RLS policies, and test data seeded into RDS (run post-deploy)
