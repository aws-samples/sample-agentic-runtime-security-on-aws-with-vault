---
title: 'Use Case 1 — Non-personalized Read-only'
weight: 50
---

:::alert{header="Content pending" type="info"}
Use Case 1 deploys a Strands agent with its own ServiceAccount (`uc1-retriever-sa`). Vault's Kubernetes auth method validates the SA's JWT against the EKS OIDC provider, binds it to the `uc1-readonly` role (TTL 15m), and issues just-in-time read-only Postgres credentials and scoped Bedrock STS credentials. **Demonstrates Objectives 1, 2, 5.**
:::
