---
title: 'Architecture'
weight: 12
---

## The IBM Verify + HashiCorp Vault answer

![Workshop Architecture](/static/images/architecture-overview.svg)

IBM Verify Identity Access owns the user-identity plane: OAuth, OIDC, CIBA, and the JWT signing key. IVIA authenticates users against your organization's Active Directory (AWS Simple AD in this workshop) via LDAP. HashiCorp Vault owns the workload-identity plane and the credential-vending plane: Kubernetes auth method bound to the EKS OIDC provider, `jwt` auth method bound to IVIA's OIDC discovery URL, and dynamic Postgres + AWS secrets engines. The two systems meet at a single seam — Vault's `jwt` auth trusts IVIA's OIDC discovery URL — which is where user intent gets converted into a Vault-vended credential.

### Responsibility split

| Plane | Owner | Scope |
|---|---|---|
| **User identity** | IBM Verify Identity Access | OAuth ROPC/PKCE, CIBA, JWT signing, JWKS endpoint, LDAP authentication against Simple AD |
| **Workload identity** | HashiCorp Vault | Kubernetes auth (ServiceAccount JWT), JWT auth (IVIA-issued id_token), policy-bound tokens |
| **Credential vending** | HashiCorp Vault | Dynamic Postgres credentials (per-use-case roles, TTL 5–15 min), AWS STS assumed_role for Bedrock |
| **Data isolation** | PostgreSQL RLS | `app.current_user_sub` session variable activates row-level security per authenticated user |
| **Network enforcement** | Kubernetes NetworkPolicy | Default-deny per namespace, per-pod egress allowlists (Vault, RDS, IVIA, Bedrock only) |
| **Encryption** | AWS KMS | Single workshop CMK encrypts RDS, S3, OpenSearch Serverless, and CloudWatch |

Verify never sees the database. Vault never authenticates an end user. Each system is the source of truth for one trust plane, and the boundary between them is a single, auditable, OIDC-mediated seam.

## How the workshop is structured

The workshop is organized into progressive modules, executed in order:

1. **Introduction** — The problem, five control objectives, architecture overview (you are here).
2. **Prerequisites** — Environment setup, pre-flight checks, HCP Terraform bootstrap.
3. **Deploy Foundation** — VPC, EKS cluster, RDS PostgreSQL, Bedrock Knowledge Base — all deployed via HCP Terraform Workspace.
4. **Platform — Vault and Verify Access** — Self-hosted Vault and IVIA on EKS, including OIDC discovery seam configuration and secrets engine wiring.
5. **Use Case 1** — Non-personalized read-only Strands agent; Vault Kubernetes auth method; JIT Postgres + Bedrock credentials.
6. **Use Case 2** — OAuth Authorization Code + PKCE; Vault `jwt` auth method; per-user database GRANTs; Kubernetes NetworkPolicy egress controls.
7. **Use Case 3 + Audit** — CIBA out-of-band approval; `may_act` and `authorization_details` enforcement via `bound_claims`; bypass test; Athena three-plane correlation query.
8. **Cleanup** — Ordered tear-down and resource verification.

Plan on roughly 3 hours end-to-end if you run with a pre-provisioned Workshop Studio account. If you're running locally, add 30–45 minutes for pre-flight quota requests and Bedrock model approval.

## What you'll have at the end

- A **3-node EKS cluster** (Kubernetes 1.33) with three deployed Strands agents, each with its own ServiceAccount and NetworkPolicy.
- A **3-node Vault Raft HA cluster** with KMS auto-unseal, Kubernetes + JWT auth methods, and dynamic Postgres + AWS secrets engines.
- **IBM Verify Identity Access (IVIA)** — self-hosted OIDC provider with OAuth clients, PKCE enforcement, and CIBA support.
- **AWS Simple AD** — lightweight managed Active Directory pre-populated with two employees (Oscar, Adriana), authenticated by IVIA via LDAP.
- **Amazon RDS PostgreSQL 17** with pgaudit, Row-Level Security policies, and Vault-managed dynamic credentials.
- **Amazon Bedrock Knowledge Base** with Nova Pro inference and Nova 2 Multimodal Embeddings, backed by OpenSearch Serverless.
- An **Athena workgroup** with the cross-plane audit correlation query joining IVIA decision logs, Vault audit logs, and AWS CloudTrail.
- **KMS encryption** across all storage (RDS, AOSS, S3, CloudWatch) under a single workshop CMK.

More importantly: the mental model and the working configuration to extend the same pattern to your own agentic systems.

