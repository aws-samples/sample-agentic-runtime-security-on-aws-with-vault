---
title: 'Architecture'
weight: 12
---

## The IBM Verify + HashiCorp Vault answer

![Workshop Architecture](/static/images/architecture-overview.png)

IBM Verify Identity Access owns the user-identity plane: OAuth, OIDC, CIBA, and the JWT signing key. IVIA authenticates users against your organization's directory (an in-cluster OpenLDAP directory in this workshop) via LDAP. HashiCorp Vault owns the workload-identity plane and the credential-vending plane: Kubernetes auth method bound to the EKS OIDC provider, `jwt` auth method bound to IVIA's OIDC discovery URL, and dynamic Postgres + AWS secrets engines. The two systems meet at a single seam — Vault's `jwt` auth trusts IVIA's OIDC discovery URL — which is where user intent gets converted into a Vault-vended credential.

### Responsibility split

| Plane | Owner | Scope |
|---|---|---|
| **User identity** | IBM Verify Identity Access | OAuth ROPC/PKCE, CIBA, JWT signing, JWKS endpoint, LDAP authentication against in-cluster OpenLDAP |
| **Workload identity** | HashiCorp Vault | Kubernetes auth (ServiceAccount JWT), JWT auth (IVIA-issued id_token), policy-bound tokens |
| **Credential vending** | HashiCorp Vault | Dynamic Postgres credentials (per-use-case roles, TTL 5–15 min), AWS STS assumed_role for Bedrock |
| **Data isolation** | PostgreSQL RLS | `app.current_user_sub` session variable activates row-level security per authenticated user |
| **Network enforcement** | Kubernetes NetworkPolicy | Default-deny per namespace, per-pod egress allowlists (Vault, RDS, IVIA, Bedrock only) |
| **Encryption** | AWS KMS | Single workshop CMK encrypts RDS, S3, OpenSearch Serverless, and CloudWatch |

Verify never sees the database. Vault never authenticates an end user. Each system is the source of truth for one trust plane, and the boundary between them is a single, auditable, OIDC-mediated seam.

## What you'll have at the end

- A **5-node EKS cluster** (min 3 / desired 5 / max 7, Kubernetes 1.34) with three deployed Strands agents, each with its own ServiceAccount and NetworkPolicy.
- A **3-node Vault Raft HA cluster** with KMS auto-unseal, Kubernetes + JWT auth methods, and dynamic Postgres + AWS secrets engines.
- **IBM Verify Identity Access (IVIA)** — self-hosted OIDC provider with OAuth clients, PKCE enforcement, and CIBA support.
- **In-cluster OpenLDAP** — IVIA's user registry, seeded with the workshop user (Oscar) by the autoconf job, authenticated by IVIA via LDAP.
- **Amazon RDS PostgreSQL 17** with pgaudit, Row-Level Security policies, and Vault-managed dynamic credentials.
- **Amazon Bedrock Knowledge Base** with Nova Pro inference and Nova 2 Multimodal Embeddings, backed by OpenSearch Serverless.
- An **Athena workgroup** with the cross-plane audit correlation query joining IVIA decision logs, Vault audit logs, and RDS pgaudit logs.
- **KMS encryption** across all storage (RDS, AOSS, S3, CloudWatch) under a single workshop CMK.

More importantly: the mental model and the working configuration to extend the same pattern to your own agentic systems.

