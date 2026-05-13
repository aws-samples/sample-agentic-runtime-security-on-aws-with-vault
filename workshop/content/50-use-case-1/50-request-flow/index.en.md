---
title: 'Request Flow'
weight: 50
---

## Overview

This module walks through the end-to-end credential and data flow for Use Case 1. No user identity is involved — the agent authenticates purely as a **workload** using its Kubernetes ServiceAccount JWT. Every credential is just-in-time, short-lived, and automatically revoked.

## Request Flow

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {
  'primaryColor': '#d0e2ff',
  'primaryTextColor': '#161616',
  'primaryBorderColor': '#0f62fe',
  'lineColor': '#0f62fe',
  'secondaryColor': '#bae6ff',
  'tertiaryColor': '#f4f4f4',
  'noteBkgColor': '#e8daff',
  'noteTextColor': '#161616',
  'noteBorderColor': '#8a3ffc',
  'actorBkg': '#d0e2ff',
  'actorBorder': '#0f62fe',
  'actorTextColor': '#161616',
  'signalColor': '#161616',
  'signalTextColor': '#161616',
  'labelBoxBkgColor': '#d0e2ff',
  'labelBoxBorderColor': '#0f62fe',
  'labelTextColor': '#161616',
  'loopTextColor': '#161616',
  'activationBorderColor': '#0f62fe',
  'activationBkgColor': '#edf5ff',
  'sequenceNumberColor': '#ffffff'
}}}%%
sequenceDiagram
    autonumber
    actor Attendee
    participant Agent as Use Case 1 Agent<br/>(Strands SDK)
    participant Vault as HashiCorp Vault
    participant EKS as EKS API<br/>(TokenReview)
    participant RDS as PostgreSQL<br/>(RDS)
    participant Bedrock as Amazon Bedrock<br/>(Nova Pro + KB)

    rect rgba(208, 226, 255, 0.3)
    Note over Agent,EKS: Pod startup — workload identity (OBJ-1)
    Agent->>Agent: Read projected SA JWT<br/>/var/run/secrets/.../token
    Agent->>Vault: POST /v1/auth/kubernetes/login<br/>{jwt: SA token, role: "uc1"}
    Vault->>EKS: TokenReview API<br/>validate SA JWT signature
    EKS-->>Vault: Confirmed: uc1-retriever-sa<br/>in namespace uc1
    Vault->>Vault: Bind to uc1-readonly policy
    Vault-->>Agent: Vault client token (TTL 1h)
    end

    rect rgba(186, 230, 255, 0.3)
    Note over Attendee,Bedrock: Query — JIT credentials (OBJ-2)
    Attendee->>Agent: POST /query<br/>"What tables exist in the database?"

    Note over Agent,RDS: Database tool — JIT Postgres creds
    Agent->>Vault: GET /v1/database/creds/uc1-readonly
    Vault->>RDS: CREATE ROLE with TTL 15 min
    Vault-->>Agent: JIT credentials {username, password}<br/>+ lease_id
    Agent->>RDS: Connect with JIT creds
    Agent->>RDS: SELECT (read-only query)
    RDS-->>Agent: Query results
    Agent->>Agent: Close connection

    Note over Agent,Bedrock: KB tool — ephemeral STS creds
    Agent->>Vault: GET /v1/aws/sts/bedrock-reader
    Vault-->>Agent: Scoped STS session<br/>{access_key, secret_key, session_token}
    Agent->>Bedrock: retrieve() — semantic search<br/>using ephemeral STS creds
    Bedrock-->>Agent: Ranked text passages
    end

    Agent->>Agent: LLM combines DB + KB results
    Agent-->>Attendee: Formatted answer

    rect rgba(167, 240, 186, 0.3)
    Note over Vault,Bedrock: Credential lifecycle
    Vault->>RDS: 15-min TTL expires → DROP ROLE
    Note over Agent,Bedrock: STS session expires (1h default)
    end
```

**Step-by-step breakdown:**

1. At pod startup, the agent reads its projected ServiceAccount JWT from the Kubernetes token volume mount (`/var/run/secrets/kubernetes.io/serviceaccount/token`).
2. The agent's `VaultClient.login()` method POSTs the SA JWT to Vault's Kubernetes auth endpoint with `role: "uc1"`.
3. Vault calls the EKS TokenReview API to validate the JWT signature and confirm the ServiceAccount identity (`uc1-retriever-sa` in namespace `uc1`).
4. Vault issues a client token bound to the `uc1-readonly` policy (TTL 1 hour). This token is cached for the pod's lifetime.
5. When a query arrives, the agent calls `query_database()` — which fetches JIT Postgres credentials from Vault's database secrets engine (`database/creds/uc1-readonly`). Vault creates an ephemeral Postgres role with a 15-minute TTL.
6. The agent connects to RDS with the JIT credentials, executes the read-only query, and closes the connection.
7. For knowledge base retrieval, the agent calls `retrieve_from_knowledge_base()` — which fetches scoped STS credentials from Vault's AWS secrets engine (`aws/sts/bedrock-reader`). Vault generates a temporary AWS session with `bedrock:InvokeModel` + `bedrock:Retrieve` permissions only.
8. The agent calls the Bedrock Knowledge Base `retrieve()` API using the ephemeral STS session.
9. The Strands LLM combines database and knowledge base results into a formatted answer.
10. After 15 minutes, Vault automatically revokes the Postgres role (`DROP ROLE`). The STS session expires at its own TTL.

## Key security properties

| Property | How it works in Use Case 1 |
|---|---|
| **No standing credentials** (OBJ-2) | The pod has no `AWS_ACCESS_KEY_ID`, no `PGPASSWORD`, no `.aws/credentials` file. Every credential is fetched from Vault per-invocation. |
| **Workload identity only** (OBJ-1) | The Vault Kubernetes auth role `uc1` is bound to `uc1-retriever-sa` in namespace `uc1`. No other ServiceAccount can obtain the `uc1-readonly` policy. |
| **Read-only enforcement** | The Vault database role `uc1-readonly` issues `GRANT SELECT` only. Even if the agent attempted `INSERT`, Postgres would reject it. |
| **Network isolation** (ENFC-03) | NetworkPolicy restricts egress to Vault (8200/TCP), RDS (5432/TCP), Bedrock (443/TCP), and DNS only. |
| **Audit correlation** (OBJ-5) | Vault audit log records the K8s auth login (SA identity) and every `database/creds` issuance (lease_id) — correlating workload identity to data access. |
