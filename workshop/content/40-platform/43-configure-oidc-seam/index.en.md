---
title: 'Configure OIDC Seam'
weight: 43
---

:::alert{header="Content pending" type="info"}
This sub-module will cover wiring the Vault Kubernetes auth method to the EKS OIDC provider, configuring Vault's `jwt` auth method against IBM Verify Access's OIDC discovery URL, and enabling the dynamic Postgres + AWS secrets engines. This is the single auditable seam where user intent becomes a Vault-vended credential.
:::
