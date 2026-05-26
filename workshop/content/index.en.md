---
title: 'Agentic Runtime Security on AWS'
weight: 0
---

Welcome to the Agentic Runtime Security on AWS workshop. Over the next ~3 hours you will deploy a real implementation of the five control objectives for AI agentic systems — every agent has a verifiable identity, no standing privileges, actions are tied to user intent, enforcement happens at the point of use, and audit evidence is correlated across all three trust planes — using the IBM Verify Identity Access + HashiCorp Vault stack on AWS EKS.

:::alert{header="Pre-flight required" type="warning"}
Before deploying any infrastructure, complete the Prerequisites module: obtain IVIA licenses, then run `infrastructure/scripts/check-prerequisites.sh` (consolidated install + Bedrock + quotas + IAM checks).
:::

## What you'll build

Three progressively-layered Strands agents on EKS, fronted by IBM Verify Identity Access (IVIA) and brokered through HashiCorp Vault, with end-to-end audit correlation:

1. **Use Case 1** — Non-personalized read-only agent (workload identity, JIT credentials)
2. **Use Case 2** — OAuth personalized read-only agent (user intent via Authorization Code + PKCE)
3. **Use Case 3** — CIBA privileged agent with three-plane audit correlation (the pedagogical money shot)

## Module index

| # | Module | What you'll do |
|---|--------|----------------|
| 10 | [Introduction](10-introduction/) | Understand the problem, five control objectives, and architecture |
| 20 | [Prerequisites](20-prerequisites/) | Set up AWS account, obtain IVIA licenses, and run pre-flight checks |
| 30 | [Deploy Foundation](30-deploy-foundation/) | Deploy VPC, EKS, RDS, Bedrock KB via local Terraform |
| 40 | [Platform — Vault & Verify Access](40-platform/) | Deploy and configure Vault + IBM Verify Identity Access on EKS |
| 50 | [Use Case 1 — Non-personalized R/O](50-use-case-1/) | Workload identity, JIT Postgres + Bedrock credentials |
| 60 | [Use Case 2 — OAuth Personalized R/O](60-use-case-2/) | User intent via OAuth PKCE, per-user DB GRANTs, NetworkPolicy |
| 70 | [Use Case 3 — CIBA Privileged](70-use-case-3/) | CIBA approval, bound_claims enforcement, three-plane audit |
| 80 | [Cleanup](80-cleanup/) | Ordered tear-down and resource verification |
| 85 | [Summary](85-summary/) | Five objectives recap and takeaway patterns |
| 90 | [Resources](90-resources/) | External references and further reading |
| 95 | [Credits](95-credits/) | Contributors and acknowledgments |
