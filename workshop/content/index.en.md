---
title: 'Agentic Runtime Security on AWS'
weight: 0
---

Welcome to the Agentic Runtime Security on AWS workshop. Over the next ~3 hours you will deploy a real implementation of the five control objectives for AI agentic systems — every agent has a verifiable identity, no standing privileges, actions are tied to user intent, enforcement happens at the point of use, and audit evidence is correlated across all three trust planes — using the IBM Verify Identity Access + HashiCorp Vault stack on AWS EKS.


## What you'll build

Three progressively-layered Strands agents on EKS, fronted by IBM Verify Identity Access (IVIA) and brokered through HashiCorp Vault, with end-to-end audit correlation:

1. **Use Case 1** — Non-personalized read-only agent (workload identity, JIT credentials)
2. **Use Case 2** — OAuth personalized read-only agent (user intent via Authorization Code + PKCE)
3. **Use Case 3** — CIBA privileged agent with three-plane audit correlation (the pedagogical money shot)

