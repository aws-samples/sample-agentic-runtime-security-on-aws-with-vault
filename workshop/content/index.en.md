---
title: 'Agentic Runtime Security on AWS'
weight: 0
---

Welcome to the Agentic Runtime Security on AWS workshop. Over the next ~3 hours you will deploy a real implementation of the five control objectives for AI agentic systems — every agent has a verifiable identity, no standing privileges, actions are tied to user intent, enforcement happens at the point of use, and audit evidence is correlated across all three trust planes — using the IBM Verify Identity Access + HashiCorp Vault stack on AWS EKS.

:::alert{header="Pre-flight required" type="warning"}
Before deploying any infrastructure, run `infrastructure/scripts/install-prereqs.sh` then the four pre-flight checks (`check-bedrock-access.sh`, `check-quotas.sh`, `check-permissions.sh`, `bootstrap.sh`).
:::

## What you'll build

Three progressively-layered Strands agents on EKS, fronted by IBM Verify Access and brokered through HashiCorp Vault, with end-to-end audit correlation:

1. **UC1** — Non-personalized read-only agent (workload identity, JIT credentials)
2. **UC2** — OAuth personalized read-only agent (user intent via Authorization Code + PKCE)
3. **UC3** — CIBA privileged agent with three-plane audit correlation (the pedagogical money shot)

## Module index

| # | Module | Phase |
|---|--------|-------|
| 10 | [Introduction](10-introduction/) | 1 |
| 20 | [Prerequisites](20-prerequisites/) | 1 |
| 30 | [Foundational Infrastructure](30-foundational/) | 2 |
| 40 | [Platform — Vault & Verify Access](40-platform/) | 3 |
| 50 | [Integration — Vault & Verify configuration](50-integration/) | 3 |
| 60 | [UC1 — Non-personalized R/O](60-uc1-non-personalized/) | 4 |
| 70 | [UC2 — OAuth Personalized R/O](70-uc2-oauth-personalized/) | 5 |
| 80 | [UC3 — CIBA Privileged](80-uc3-ciba-privileged/) | 6 |
| 90 | [Audit & Observability](90-audit-and-observe/) | 6 |
| 95 | [Cleanup](95-cleanup/) | 7 |
| 97 | [Appendices](97-appendices/) | 7 |
| 98 | [Summary](98-summary/) | 7 |
| 99 | [Resources](99-resources/) | 7 |
| 99 | [Credits](99-credits/) | 1 |
