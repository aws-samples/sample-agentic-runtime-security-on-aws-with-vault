---
title: 'Deploy Foundation'
weight: 30
---

In this module you stand up the workshop stack — VPC, EKS, RDS, Bedrock Knowledge Base, Vault, IBM Verify Identity Access, and the Use Case workloads — then verify it came up healthy. Later modules only verify what this deploy produces; they don't apply their own Terraform.

How much of that you deploy yourself depends on how you are running the workshop:

- **[At an event](./31-deploy-at-an-event/)** — Tier 1 (foundation) and Tier 2 (Vault + IVIA) were deployed into your account during setup. You pull the pre-provisioned state, **verify** those two tiers, and deploy **Tier 3** (the Use Case workloads) yourself.
- **[Self-paced](./31-deploy-self-paced/)** — you deploy all three tiers on your own AWS account with one command.

From [Configure kubectl](./32-configure-kubectl/) onward the pages are identical for both paths.

Complete the [Prerequisites module](../20-prerequisites/) first, then work through the sub-modules in the left nav in order.
