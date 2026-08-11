# Alternative Architecture — Amazon Bedrock AgentCore + HashiCorp Vault

Companion notes for the diagram:

- Source (editable): [`architecture-overview-agentcore.svg`](./architecture-overview-agentcore.svg)
- Rendered preview: [`architecture-overview-agentcore.png`](./architecture-overview-agentcore.png)

Both use the same dark `#0d1117` theme, palette, fonts, and 1600×920 canvas as the reference [`architecture-overview.svg`](./architecture-overview.svg), so the two read as siblings.

## Overview

This is an **alternative** to the workshop's IBM Verify + HashiCorp Vault reference architecture. The **credential-vending core stays identical** — Vault Enterprise is still the star. What gets swapped out is the *entire identity plane and the agent runtime*.

When a user invokes an AgentCore-hosted agent, **AgentCore Identity** issues a JWT carrying that user's identity. The agent presents that token to **Vault**, whose OAuth resource server validates it via JWKS, resolves it to a Vault identity entity, checks the **Agent Registry**, and enforces per-request (ephemeral) authorization — then issues short-lived dynamic credentials scoped to exactly what the task needs. When the JWT expires, the authorization expires with it. No standing access, no stored tokens, no static secrets anywhere in the flow.

**Net effect:** the IBM Verify + OpenLDAP + EKS-hosting stack collapses into AWS-managed AgentCore, while Vault stays exactly where it is as the enforcement + credential-vending backbone. It is AWS-only (AgentCore is not multi-cloud), and Vault's native AI-agent support is a **beta** feature (Vault Enterprise 2.0.3+).

## What changes vs. the current (IVIA + Vault) architecture

| Layer | Current workshop | Alternative (AgentCore) |
|---|---|---|
| **User-identity issuer** | IBM Verify Identity Access (self-hosted OIDC/CIBA on EKS) | **Amazon Bedrock AgentCore Identity** issues the JWT carrying user context |
| **User directory / auth** | In-cluster **OpenLDAP** + IVIA (ROPC/PKCE/CIBA) | Pluggable **external OIDC IdP** (Cognito · Okta · Entra ID · IBM Verify) — IVIA demoted to *one option* |
| **Agent runtime** | Self-managed **EKS** pods (ServiceAccount + NetworkPolicy per agent) | **AgentCore Runtime** — managed, serverless, framework-agnostic (Strands · LangGraph · LlamaIndex · AutoGen) |
| **Workload identity → Vault** | Vault **Kubernetes auth method** (SA JWT bound to EKS OIDC) | **AgentCore workload identity** (agent ARN) + JWT presented directly to Vault's OAuth resource server — K8s auth retired |
| **On-behalf-of token store** | IVIA / in-cluster (CIBA out-of-band consent) | **AgentCore Secure Token Vault** stores user-delegated OAuth tokens |
| **The seam** | Vault ↔ **IVIA** JWKS | Vault ↔ **AgentCore Identity** JWKS |
| **Audit** | 3-plane JOIN (IVIA + Vault + RDS pgaudit) via Athena | **One stream** — Vault's tamper-evident log (agent id + user id + JWT claims + lease) |

### Unchanged (the constant)

Vault Enterprise's **Agent Registry**, **ephemeral authorization** (`authorization_details` claim), **dynamic secrets engine** (Postgres · MySQL · MongoDB · AWS IAM · SSH · PKI · KV), short-lived auto-revoked credentials, end-to-end user attribution, and Terraform provisioning.

## Request flow (as numbered in the diagram)

1. User authenticates to the OIDC IdP and invokes the AgentCore-hosted agent.
2. AgentCore Identity issues a JWT carrying the user's identity/context.
3. The agent presents the JWT to Vault; Vault's OAuth resource server validates it via JWKS (**the seam**), checks the Agent Registry, and authorizes the request.
4. Vault issues short-lived dynamic credentials scoped to the task.
5. The agent accesses the protected resource (database, AWS, API) with those JIT credentials.
6. Vault's tamper-evident audit log records every credential request (agent identity + resolved user identity + JWT metadata + lease ID).
7. The agent streams the answer back to the user.

## Caveats (from the PR/FAQ)

- **Vault Enterprise required** — Agent Registry, OAuth resource server, and ephemeral authorization are Enterprise-only (2.0.3+ / HCP Vault Dedicated).
- **Beta** — HashiCorp discourages production use of the beta AI-agent features until GA.
- **AWS-only runtime** — AgentCore does not cover Azure / Google / on-prem agent runtimes (Vault's secrets plane supports them independently).
- **Multi-hop complexity** — the pattern covers single-agent and two-hop flows; deeper orchestration needs additional design.
