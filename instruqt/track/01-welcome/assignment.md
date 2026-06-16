---
slug: welcome
type: challenge
title: Welcome to Agentic Runtime Security on AWS
teaser: Five control objectives, three use cases, one EKS cluster.
tabs:
  - title: Terminal
    type: terminal
    hostname: shell
---

Welcome to the **Agentic Runtime Security on AWS** workshop. Over the next ~4 hours
you will deploy a real implementation of the five control objectives for AI agentic
systems on AWS EKS, then walk three progressively-layered use cases end-to-end.

## The problem

AI agentic systems break the assumptions security tooling has relied on for two
decades. Agents are not users — they don't fit IAM Identity Center personas.
Agents are not workloads in the classic sense — they're sometimes acting on
behalf of a user, sometimes acting autonomously, and the boundary moves request
to request. Bearer tokens with hard-coded scopes don't compose. Standing
database credentials with broad GRANTs accumulate sprawl with every new agent.
And when something goes wrong, "which user authorized this action?" becomes
unanswerable across IDP logs, IAM logs, and database logs that don't share a
correlation key.

The agentic-systems threat model stretches across three trust planes
simultaneously — **user identity** (who is asking?), **workload identity** (which
agent process is acting?), and **data plane** (what credentials does it actually
present to Postgres or Bedrock?). Most existing tooling owns one plane and
assumes the other two are someone else's problem. That assumption is what this
workshop dismantles.

## Five control objectives

1. **Verifiable identity** — every agent ties back to a cryptographically
   verifiable identity (workload SA, user OAuth flow, or both).
2. **No standing privileges** — credentials are issued just-in-time, scoped to
   the request, and revoked when the work is done.
3. **Actions tied to user intent** — privileged actions require demonstrable
   user consent (OAuth Authorization Code + PKCE for read access, CIBA
   out-of-band for writes).
4. **Enforcement at the point of use** — three layers of defense (Vault
   policies, DB GRANTs + AWS IAM, Kubernetes NetworkPolicy) so a compromise of
   any one layer doesn't bypass the others.
5. **Correlated audit evidence** — a single propagated `request_id` joins IVIA
   decision logs, HashiCorp Vault audit logs, and RDS pgaudit logs in Athena.

## Three use cases, in topological order

Use Case 3 is a strict superset of Use Case 1 + Use Case 2 — every challenge
builds on the previous one.

**Use Case 1 — Non-personalized read-only retrieval.** A Strands agent runs in
EKS with its own ServiceAccount (`uc1-retriever-sa`). Vault's Kubernetes auth
method validates the SA's JWT against the EKS OIDC provider, binds it to the
`uc1` auth role (token TTL 1h, carrying the `uc1-readonly` policy), and issues
just-in-time read-only Postgres credentials via `database/creds/uc1-readonly`
(credential TTL 15 min) and scoped Bedrock STS credentials. **Demonstrates
Objectives 1, 2, 5.**

**Use Case 2 — OAuth personalized read-only.** The agent now requires a user
JWT (Authorization Code + PKCE flow against IBM Verify Access). The user JWT
is exchanged via Vault's `jwt` auth method (`bound_audiences=["agent-uc2"]`)
for per-user-scoped database credentials. INSERT attempts are rejected by DB
GRANTs (Layer 2 enforcement). Egress to unapproved endpoints is blocked by
Kubernetes NetworkPolicy (Layer 3). **Adds Objective 3.**

**Use Case 3 — CIBA privileged + three-plane audit correlation.** Privileged
actions trigger a CIBA out-of-band approval flow with mobile-push consent on
your phone. The resulting JWT carries `may_act` (RFC 8693 Token Exchange) and
`authorization_details` (RFC 9396 RAR) claims, enforced by Vault `bound_claims`.
A bypass test confirms that forged `may_act` claims are rejected. A single
Athena query joins IVIA decision logs + Vault audit logs + RDS pgaudit logs by
`request_id` and answers "Which user authorized this action, when, against
what system, and was access revoked?" **Demonstrates all 5 Objectives.**

{% hint style="info" %}
The sandbox AWS account, your SSH deploy key, and your `~/.aws/credentials`
were configured automatically when this track started — you do **not** need
to `aws configure` or `export AWS_PROFILE`. Try `aws sts get-caller-identity`
in the Terminal tab to confirm.
{% endhint %}

When you're ready, advance to the next challenge.
