---
title: 'Introduction'
weight: 10
---

## The problem

AI agentic systems break the assumptions security tooling has relied on for two decades. Agents are not users — they don't fit IAM Identity Center personas. Agents are not workloads in the classic sense — they're sometimes acting on behalf of a user, sometimes acting autonomously, and the boundary moves request to request. Bearer tokens with hard-coded scopes don't compose. Standing database credentials with broad GRANTs accumulate sprawl with every new agent. And when something goes wrong, "which user authorized this action?" becomes unanswerable across IDP logs, IAM logs, and database logs that don't share a correlation key.

The agentic-systems threat model stretches across three trust planes simultaneously — user identity (who is asking?), workload identity (which agent process is acting?), and data plane (what credentials does it actually present to Postgres or Bedrock?). Most existing tooling owns one plane and assumes the other two are someone else's problem. That assumption is what this workshop dismantles.

## Five control objectives

This workshop focuses on five control objectives for agentic systems:

1. **Verifiable identity** — every agent ties back to a cryptographically verifiable identity (workload SA, user OAuth flow, or both).
2. **No standing privileges** — credentials are issued just-in-time, scoped to the request, and revoked when the work is done.
3. **Actions tied to user intent** — privileged actions require demonstrable user consent (OAuth Authorization Code + PKCE for read access, CIBA out-of-band for writes).
4. **Enforcement at the point of use** — three layers of defense (Vault policies, DB GRANTs + AWS IAM, Kubernetes NetworkPolicy) so a compromise of any one layer doesn't bypass the others.
5. **Correlated audit evidence** — a single propagated `request_id` joins IBM Verify Access decision logs, HashiCorp Vault audit logs, and AWS CloudTrail in Athena.

## The IBM Verify + HashiCorp Vault answer

![Reference architecture](/static/images/architecture-overview.svg)

IBM Verify Identity Access owns the user-identity plane: OAuth, OIDC, CIBA, and the JWT signing key. HashiCorp Vault owns the workload-identity plane and the credential-vending plane: Kubernetes auth method bound to the EKS OIDC provider, `jwt` auth method bound to Verify's OIDC discovery URL, and dynamic Postgres + AWS secrets engines. The two stacks meet at a single seam — Vault's `jwt` auth trusts Verify's OIDC discovery URL — which is where user intent gets converted into a Vault-vended credential.

![Verify and Vault responsibility split](/static/images/verify-vault-split.svg)

The diagram above shows the responsibility split. Verify never sees the database. Vault never authenticates an end user. Each system is the source of truth for one trust plane, and the boundary between them is a single, auditable, OIDC-mediated seam.

## Three use cases, in order

The workshop walks through three use cases in strict topological order — UC3 is a strict superset of UC1 + UC2.

:::expand{header="UC1 — Non-personalized read-only retrieval"}
A Strands agent runs in EKS with its own ServiceAccount (`uc1-retriever-sa`). Vault's Kubernetes auth method validates the SA's JWT against the EKS OIDC provider, binds it to the `uc1-readonly` role (TTL 15m), and issues just-in-time read-only Postgres credentials and scoped Bedrock STS credentials. **Demonstrates Objectives 1, 2, 5.**
:::

:::expand{header="UC2 — OAuth personalized read-only"}
The agent now requires a user JWT (Authorization Code + PKCE flow against IBM Verify Access). The user JWT is exchanged via Vault's `jwt` auth method (`bound_audiences=["agent-uc2"]`) for per-user-scoped database credentials. INSERT attempts are rejected by DB GRANTs (Layer 2 enforcement). Egress to unapproved endpoints is blocked by Kubernetes NetworkPolicy (Layer 3). **Adds Objective 3.**
:::

:::expand{header="UC3 — CIBA privileged + three-plane audit correlation"}
Privileged actions trigger a CIBA out-of-band approval flow. The resulting JWT carries `may_act` (RFC 8693 Token Exchange) and `authorization_details` (RFC 9396 RAR) claims, enforced by Vault `bound_claims`. A bypass test confirms that forged `may_act` claims are rejected. A single Athena query joins IVIA decision logs + Vault audit logs + AWS CloudTrail by `request_id` and answers "Which user authorized this action, when, against what system, and was access revoked?" **Demonstrates all 5 Objectives.**
:::

## What you'll have at the end

A running EKS cluster with three deployed agents, a configured Vault cluster, a configured IBM Verify Identity Access instance, and an Athena workgroup with the cross-plane audit query saved. More importantly: the mental model and the working configuration to extend the same pattern to your own agentic systems.

## Audience and scope

This workshop targets platform, security, and identity engineers who are building (or about to build) agentic systems on AWS and need to make defensible answers to the five objectives above. Some familiarity with Kubernetes (`kubectl`, ServiceAccounts), Terraform, and OAuth/OIDC concepts is assumed. Prior IBM Verify Access or HashiCorp Vault expertise is **not** required — the workshop walks through configuration of both stacks from a clean slate.

Out of scope: model fine-tuning, prompt-injection defense at the LLM layer, and human-to-human IAM (this workshop is about identity for agents, not for the people who write the code that builds the agents). Those topics matter; they're just not what this workshop solves.

## How the workshop is structured

The workshop is organized into seven phases, executed in order:

1. **Phase 1 — Scaffold and Pre-Flight.** Repository scaffolding, slide deck, diagrams, and pre-flight environment validation scripts (the module you're reading right now is part of Phase 1's content output).
2. **Phase 2 — Foundational Infrastructure.** VPC, EKS cluster (with Karpenter), RDS PostgreSQL, and Bedrock Knowledge Base — all deployed via Terraform Stacks.
3. **Phase 3 — Platform: Vault and IBM Verify Access.** Self-hosted Vault and IVIA on EKS, including OIDC discovery seam configuration.
4. **Phase 4 — UC1.** Non-personalized read-only Strands agent; Vault Kubernetes auth method; JIT Postgres + Bedrock credentials.
5. **Phase 5 — UC2.** OAuth Authorization Code + PKCE; Vault `jwt` auth method; per-user database GRANTs; Kubernetes NetworkPolicy egress controls.
6. **Phase 6 — UC3 + Audit.** CIBA out-of-band approval; `may_act` and `authorization_details` enforcement via `bound_claims`; bypass test; Athena three-plane correlation query.
7. **Phase 7 — Cleanup, Summary, and Resources.** Tear-down, recap of the five objectives, and next-step references.

Plan on roughly 3 hours end-to-end if you run with a pre-provisioned Workshop Studio account. If you're running locally, add 30–45 minutes for pre-flight quota requests and Bedrock model approval.

## A note on the design tax

The workshop pays its audit-correlation design tax up front. In Phase 2 — before any agent code exists — `request_id` propagation conventions and CloudWatch log retention are documented and codified. That looks like over-engineering when the only thing running is a VPC, but it pays off in Phase 6 when a single Athena query joins three otherwise-disjoint log streams. Most real-world agentic deployments skip this tax and then discover it's effectively impossible to retrofit; the workshop deliberately models the harder, correct sequencing.

The same logic applies to enforcement layering. The workshop does not stop at "Vault issues a scoped credential." It also configures DB GRANTs (so a leaked credential still can't run `INSERT`) and Kubernetes NetworkPolicy egress restrictions (so a compromised pod can't exfiltrate to an attacker endpoint). Three layers of independent enforcement is the floor, not the ceiling.

## Ready

Continue to [Prerequisites](../20-prerequisites/) to set up your environment.
