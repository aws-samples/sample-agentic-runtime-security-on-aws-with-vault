---
title: 'Architecture'
weight: 12
---

## The IBM Verify + HashiCorp Vault answer

![Reference architecture](/static/images/architecture-overview.svg)

IBM Verify Identity Access owns the user-identity plane: OAuth, OIDC, CIBA, and the JWT signing key. HashiCorp Vault owns the workload-identity plane and the credential-vending plane: Kubernetes auth method bound to the EKS OIDC provider, `jwt` auth method bound to Verify's OIDC discovery URL, and dynamic Postgres + AWS secrets engines. The two stacks meet at a single seam — Vault's `jwt` auth trusts Verify's OIDC discovery URL — which is where user intent gets converted into a Vault-vended credential.

![Verify and Vault responsibility split](/static/images/verify-vault-split.svg)

The diagram above shows the responsibility split. Verify never sees the database. Vault never authenticates an end user. Each system is the source of truth for one trust plane, and the boundary between them is a single, auditable, OIDC-mediated seam.

## How the workshop is structured

The workshop is organized into progressive modules, executed in order:

1. **Introduction** — The problem, five control objectives, architecture overview (you are here).
2. **Prerequisites** — Environment setup, pre-flight checks, HCP Terraform bootstrap.
3. **Deploy Foundation** — VPC, EKS cluster, RDS PostgreSQL, Bedrock Knowledge Base — all deployed via Terraform Stacks.
4. **Platform — Vault and Verify Access** — Self-hosted Vault and IVIA on EKS, including OIDC discovery seam configuration and secrets engine wiring.
5. **Use Case 1** — Non-personalized read-only Strands agent; Vault Kubernetes auth method; JIT Postgres + Bedrock credentials.
6. **Use Case 2** — OAuth Authorization Code + PKCE; Vault `jwt` auth method; per-user database GRANTs; Kubernetes NetworkPolicy egress controls.
7. **Use Case 3 + Audit** — CIBA out-of-band approval; `may_act` and `authorization_details` enforcement via `bound_claims`; bypass test; Athena three-plane correlation query.
8. **Cleanup** — Ordered tear-down and resource verification.

Plan on roughly 3 hours end-to-end if you run with a pre-provisioned Workshop Studio account. If you're running locally, add 30–45 minutes for pre-flight quota requests and Bedrock model approval.

## A note on the design tax

The workshop pays its audit-correlation design tax up front. In the Deploy Foundation module — before any agent code exists — `request_id` propagation conventions and CloudWatch log retention are documented and codified. That looks like over-engineering when the only thing running is a VPC, but it pays off in Use Case 3 when a single Athena query joins three otherwise-disjoint log streams. Most real-world agentic deployments skip this tax and then discover it's effectively impossible to retrofit; the workshop deliberately models the harder, correct sequencing.

The same logic applies to enforcement layering. The workshop does not stop at "Vault issues a scoped credential." It also configures DB GRANTs (so a leaked credential still can't run `INSERT`) and Kubernetes NetworkPolicy egress restrictions (so a compromised pod can't exfiltrate to an attacker endpoint). Three layers of independent enforcement is the floor, not the ceiling.
