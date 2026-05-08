---
title: 'Use Case 2 — OAuth Personalized Read-only'
weight: 60
---

:::alert{header="Content pending" type="info"}
Use Case 2 requires a user JWT (Authorization Code + PKCE flow against IBM Verify Access). The user JWT is exchanged via Vault's `jwt` auth method (`bound_audiences=["agent-uc2"]`) for per-user-scoped database credentials. INSERT attempts are rejected by DB GRANTs (Layer 2 enforcement). Egress to unapproved endpoints is blocked by Kubernetes NetworkPolicy (Layer 3). **Adds Objective 3.**
:::
