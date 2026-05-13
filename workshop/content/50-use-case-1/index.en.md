---
title: 'Use Case 1 — Non-Personalized Read-Only'
weight: 50
---

## Overview

Use Case 1 deploys a Strands agent that authenticates to Vault using its own Kubernetes ServiceAccount (`uc1-retriever-sa`), receives just-in-time credentials, and queries both Amazon RDS (Postgres) and a Bedrock Knowledge Base. No user identity is involved — this is **pure workload identity**.

The agent pod never holds a long-lived database password or an AWS IAM credential. Every time the agent handles a query, it presents its ServiceAccount JWT to Vault, receives a time-boxed Postgres credential (TTL 15 min) and a scoped Bedrock STS credential, uses them to answer the question, and then those credentials expire automatically.

## Objectives Covered

| Objective | ID | How Use Case 1 Demonstrates It |
|---|---|---|
| Every agent has a verifiable identity | OBJ-1 | Vault's Kubernetes auth method validates the pod's ServiceAccount JWT against the EKS OIDC provider — only `uc1-retriever-sa` in the `uc1` namespace can obtain the `uc1-readonly` Vault token |
| No standing privileges — JIT credentials only | OBJ-2 | Postgres credentials are issued with a 15-minute TTL; Bedrock access is a scoped STS session from Vault; neither credential exists on disk or in environment variables at rest |
| Audit trail ties credential issuance to agent identity | OBJ-5 | Every Vault dynamic credential issuance event is written to the Vault audit log with the SA-bound principal — you will observe this entry in the verification module |

## What You Will Learn

- How a Kubernetes ServiceAccount JWT becomes a Vault token (the Kubernetes auth trust chain)
- How the `hvac` Python SDK makes the credential-fetch code visible and auditable — no opaque sidecar
- Why the agent pod has no AWS IAM role attached (IRSA deliberately absent for OBJ-2)
- How Vault's NetworkPolicy egress rules constrain what the pod can reach
- How to verify JIT credential issuance and enforce the boundary between Use Case 1 and Use Case 3 credential scopes

## Sub-Modules

| Module | What You Do |
|---|---|
| [Request Flow](./50-request-flow/) | Walk through the end-to-end credential and data flow — workload identity, JIT Postgres + STS credentials, and automatic revocation |
| [Deploy the Use Case 1 Agent](./51-deploy-agent/) | Build and push the agent container, update terraform.tfvars with the image URI, trigger the workspace apply, and verify the pod and ServiceAccount are running |
| [Configure Vault Auth for Use Case 1](./52-configure-vault-auth/) | Inspect the Vault role and policy that were configured by the `vault_config` Terraform module — understand what was configured and why |
| [Verify Credentials and Enforcement](./53-verify-credentials/) | Query the agent, observe JIT credential issuance in the Vault audit log, run the enforcement test, and review the threat-model callout |

## Prerequisites

You must have completed the **Platform** module (Phase 3) before starting here. Specifically, the following Terraform modules must be in applied state:

- `vault` — Vault HA cluster running and initialized
- `vault_config` — Kubernetes auth backend, `uc1-readonly` policy, `uc1` Kubernetes auth role, and `uc1-readonly` database credentials role configured
- `rds` — Postgres instance running and accepting connections
- `bedrock_kb_index` — Knowledge Base indexed with corpus documents
