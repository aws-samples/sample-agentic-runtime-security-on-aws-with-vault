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
| Every agent has a verifiable identity | OBJ-1 | The MCP Server authenticates to Vault with its own Kubernetes ServiceAccount (`uc2-mcp-server-sa`) — only that SA in the `banking-app` namespace can obtain a `uc2-personal` Vault token |
| No standing privileges — JIT credentials only | OBJ-2 | Per-user Postgres credentials are issued dynamically via Vault's database secrets engine with a 15-minute TTL; no credential is stored on disk or in environment variables at rest |
| Actions tied to user intent | OBJ-3 | The user's IVIA-issued JWT carries the `sub` claim (user identity); the MCP Server presents that JWT to Vault's `jwt` auth method; Vault maps the sub claim to per-user-scoped DB credentials; the database enforces Row-Level Security so each user sees only their own rows |
| Enforcement at the point of use | ENFC-02 | The Vault policy for `uc2-personal` grants only `database/creds/uc2-personal-readonly`; Postgres GRANTs exclude INSERT — so even if the Vault policy were widened, the DB GRANT layer still rejects writes |
| Enforcement at the point of use | ENFC-03 | Kubernetes NetworkPolicy restricts MCP Server egress to Vault, RDS, and DNS only — external HTTP calls are blocked at the network layer |
| Audit trail ties credential issuance to user identity | OBJ-5 | The Vault audit log records both the jwt auth login (with the user's `sub` claim) and the subsequent database/creds issuance — providing a correlated audit trail from user identity to data access |

## Architecture

The diagram below shows the full credential and data flow for Use Case 2.

![Use Case 2 OAuth flow diagram](../assets/uc2-flow.svg)

### Request flow

1. The user opens the Banking UI in a browser. The SvelteKit frontend detects no active session and redirects to IVIA's OAuth authorization endpoint.
2. The user authenticates with IVIA (username and password). IVIA issues an authorization code and redirects the browser back to the Banking UI callback URL.
3. The SvelteKit server-side `/callback` route exchanges the authorization code for an access token + ID token using PKCE verification.
4. The Banking UI passes the user's JWT in the `Authorization: Bearer` header of every API call to the Banking Agent.
5. The Banking Agent forwards the JWT (unchanged) to the MCP Server for each tool invocation.
6. The MCP Server presents the JWT to Vault's `jwt` auth method (`POST /v1/auth/jwt/login`). Vault validates the JWT signature against IVIA's JWKS endpoint and evaluates the `bound_audiences` claim (`agent-uc2`).
7. Vault issues a short-lived token bound to the `uc2-personal` policy.
8. The MCP Server uses that token to call `database/creds/uc2-personal-readonly`. Vault issues a JIT Postgres credential.
9. The MCP Server opens a Postgres connection using the JIT credential, sets `app.current_user_sub = '<jwt-sub>'` as a session-level setting, and executes `SELECT` queries. PostgreSQL Row-Level Security filters each query to the authenticated user's rows only.
10. The credential expires at TTL; Vault revokes the Postgres role automatically.

## Services Deployed

| Service | Runtime | Port | Role |
|---|---|---|---|
| Banking UI | SvelteKit (Node 22) | 5173 | Browser OAuth flow, JWT custody, Agent API calls |
| Banking Agent | Python / Strands SDK | 3002 | LLM orchestration, tool routing via MCP |
| MCP Server | Node.js / Express | 3001 | Vault JWT auth, JIT DB credentials, query execution |

All three pods run in the `banking-app` namespace. Separate ALB Ingress exposes the Banking UI externally. Agent and MCP Server are ClusterIP-only — no external exposure.

## What You Will Learn

- OAuth Authorization Code + PKCE flow: `code_verifier`, `code_challenge`, S256 hashing
- How IVIA acts as the identity provider and issues JWTs with user `sub`, `aud`, and `azp` claims
- How Vault's `jwt` auth method validates an IVIA JWT without requiring a confidential client secret at the Vault layer
- How per-user Postgres credentials are scoped using Vault's database secrets engine and PostgreSQL Row-Level Security
- How the MCP Server (not the agent) holds the credential-fetching responsibility — the agent never sees a DB credential
- How Layer 2 (DB GRANTs) and Layer 3 (NetworkPolicy) enforcement work in combination as defense-in-depth
- How Vault credential revocation cascades from user logout to lease expiry to Postgres role removal
- How the Vault audit log links a `sub` claim to a `database/creds` issuance — OBJ-5 audit correlation

## Prerequisites

You must have completed the **Platform** module (Phase 3) before starting here. Specifically:

- `vault` — Vault HA cluster running and initialized
- `vault_config` — Kubernetes auth backend, jwt auth backend (pointing to IVIA OIDC discovery), `uc2-personal` policy, `uc2` Kubernetes auth role, `uc2-jwt` JWT auth role, and `uc2-personal-readonly` database credentials role configured
- `verify_access` — IVIA OIDC provider deployed with `agent-uc2` OAuth client (PKCE required, authorization_code grant) configured declaratively via config.yaml
- `uc2_app` — Banking UI, Banking Agent, and MCP Server deployed via the HCP Terraform workspace
- `seed-banking-db.sh` — Banking schema, RLS policies, and test data seeded into RDS (run post-deploy)

## Sub-Modules

| Module | What You Do |
|---|---|
| [OAuth Authorization Code + PKCE Flow](./61-oauth-pkce-flow/) | Understand the PKCE flow, log in as Oscar or Adriana, and inspect the JWT claims in the banking app |
| [Vault JWT Authentication](./62-configure-jwt-auth/) | Inspect the Vault jwt auth role and policy, trace the token exchange from user JWT to DB credential |
| [Verify Per-User Data Access](./63-verify-user-access/) | Confirm per-user data isolation with RLS, run verify-uc2.sh, review the threat-model callout |
| [Scope Enforcement (Layer 2)](./64-scope-enforcement/) | Demonstrate Vault policy denial of write roles and Postgres INSERT rejection |
| [Credential Revocation](./65-credential-revocation/) | Observe the active lease, log out, confirm lease revocation, and find the audit log event |
