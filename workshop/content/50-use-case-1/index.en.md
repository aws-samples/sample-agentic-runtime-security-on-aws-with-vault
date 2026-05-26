---
title: 'Use Case 1 — Non-Personalized Read-Only'
weight: 50
---

## Overview

Use Case 1 is a Strands agent that authenticates to Vault using its own Kubernetes ServiceAccount (`uc1-retriever-sa`), receives just-in-time credentials, and queries both Amazon RDS (Postgres) and a Bedrock Knowledge Base. No user identity is involved — this is **pure workload identity**.

The agent pod never holds a long-lived database password or an AWS IAM credential. Every time it handles a query, it presents its ServiceAccount JWT to Vault, receives a time-boxed Postgres credential (TTL 15 min) and a scoped Bedrock STS credential, answers the question, and lets those credentials expire automatically.

The agent was already deployed with the Deploy Foundation `terraform apply`. In this module you inspect its Vault configuration, verify JIT credential issuance, and test the enforcement boundary against Use Case 3.

## Objectives Covered

| Objective | ID | How Use Case 1 Demonstrates It |
|---|---|---|
| Every agent has a verifiable identity | OBJ&#8209;1 | Vault's Kubernetes auth method validates the pod's ServiceAccount JWT against the EKS OIDC provider — only `uc1-retriever-sa` in the `uc1` namespace can obtain the `uc1-readonly` Vault token |
| No standing privileges — JIT credentials only | OBJ&#8209;2 | Postgres credentials are issued with a 15-minute TTL; Bedrock access is a scoped STS session from Vault; neither credential exists on disk or in environment variables at rest |
| Audit trail ties credential issuance to agent identity | OBJ&#8209;5 | Every Vault dynamic credential issuance event is written to the Vault audit log with the SA-bound principal — you will observe this entry in the verification module |

## What You Will Learn

- How a Kubernetes ServiceAccount JWT becomes a Vault token (the Kubernetes auth trust chain)
- How to inspect the Vault policy, role binding, and database secrets engine that scope the agent
- How to verify just-in-time credential issuance in the Vault audit log
- How to prove the Use Case 1 identity cannot obtain Use Case 3 credentials (ENFC-01)

## Prerequisites

You must have completed the **Deploy Foundation** module before starting here. Specifically, the following Terraform modules must be in applied state:

- `vault` — Vault HA cluster running and initialized
- `vault_config` — Kubernetes auth backend, `uc1-readonly` policy, `uc1` Kubernetes auth role, and `uc1-readonly` database credentials role configured
- `rds` — Postgres instance running and accepting connections
- `bedrock_kb_index` — Knowledge Base indexed with corpus documents
