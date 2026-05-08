---
title: 'Platform — Vault and Verify Access'
weight: 40
---

:::alert{header="Content pending" type="info"}
This module covers deploying and configuring the full platform layer on EKS:

- **Deploy Vault** — 3 Raft pods (one per AZ), auto-unseal via KMS, audit device to `/workshop/vault-audit`.
- **Deploy Verify Access** — IBM Verify Identity Access 11.0.2 self-hosted, ALB-fronted, decision logs to `/workshop/ivia-decision`.
- **Configure OIDC Seam** — Vault Kubernetes auth method bound to EKS OIDC provider, Vault `jwt` auth method bound to Verify's OIDC discovery URL, dynamic Postgres + AWS secrets engines.
- **Verify Platform** — Seal status, health endpoints, OIDC discovery, log delivery.

The Vault `jwt` auth trusting Verify's OIDC discovery URL is the single seam where user intent becomes a Vault-vended credential — the architectural keystone the three use cases build on.
:::
