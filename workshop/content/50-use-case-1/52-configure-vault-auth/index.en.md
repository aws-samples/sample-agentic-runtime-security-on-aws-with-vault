---
title: 'Configure Vault Auth for Use Case 1'
weight: 52
---

## Overview

The Vault Kubernetes auth method, database secrets engine role, AWS secrets engine role, and access policy for Use Case 1 were all configured by the `vault_config` Terraform module in Phase 3 (applied via the HCP Terraform workspace). **You do not need to reconfigure anything in this module.**

This page explains what was configured and why — understanding the Vault trust chain is essential before you observe credential issuance in the next module.

## Step 1 — Inspect the Vault role binding

Export the Vault address so `vault` CLI commands work from your local machine (via `kubectl port-forward` or an ALB endpoint):

```bash
export VAULT_ADDR=http://localhost:8200

# If you need to port-forward:
kubectl port-forward -n vault svc/vault 8200:8200 &
```

Read the Kubernetes auth role that binds `uc1-retriever-sa` to the `uc1-readonly` policy:

```bash
vault read auth/kubernetes/role/uc1
```

Expected output:

```
Key                                 Value
---                                 -----
alias_name_source                   serviceaccount_uid
bound_service_account_names         [uc1-retriever-sa]
bound_service_account_namespaces    [uc1]
policies                            [uc1-readonly]
token_ttl                           1h
token_max_ttl                       24h
token_type                          default
```

Key observations:

- `bound_service_account_names` is `[uc1-retriever-sa]` — only this SA in namespace `uc1` can obtain this role.
- `policies` is `[uc1-readonly]` — the Vault token issued after login is scoped to this policy only.
- `token_ttl` is 1 hour — the Vault session (not the database credential) lifetime.

## Step 2 — Inspect the uc1-readonly policy

```bash
vault policy read uc1-readonly
```

Expected output:

```hcl
path "database/creds/uc1-readonly" {
  capabilities = ["read"]
}

path "aws/sts/bedrock-reader" {
  capabilities = ["read", "update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "sys/leases/renew" {
  capabilities = ["update"]
}
```

Each policy path serves a specific purpose:

| Path | Capabilities | Purpose |
|---|---|---|
| `database/creds/uc1-readonly` | `read` | Issue JIT Postgres read-only credentials (TTL 15 min) |
| `aws/sts/bedrock-reader` | `read`, `update` | Generate a scoped AWS STS session for Bedrock Knowledge Base access |
| `auth/token/lookup-self` | `read` | Agent can inspect its own Vault token TTL and policies — used for introspection and token renewal decisions |
| `sys/leases/renew` | `update` | Renew active credential leases before TTL expiry if the agent query takes longer than expected |

Notice what is **not** in the policy:

- No `database/creds/uc3-refund-writer` — Use Case 3 credentials are completely out of scope for this policy.
- No `aws/iam/*` — the agent cannot create or modify IAM resources.
- No `sys/mounts` — the agent cannot create new secrets engine mounts.

## Step 3 — Verify the Kubernetes auth method is enabled

```bash
vault auth list
```

Look for the `kubernetes/` mount in the output:

```
Path           Type          Description
----           ----          -----------
kubernetes/    kubernetes    n/a
token/         token         token based credentials
```

Verify the Kubernetes auth configuration points to the EKS cluster:

```bash
vault read auth/kubernetes/config
```

The `kubernetes_host` field should show the EKS API server endpoint. This is the address Vault calls when validating an incoming SA JWT via the Kubernetes TokenReview API.

## Step 4 — Verify the database secrets engine role

```bash
vault read database/roles/uc1-readonly
```

Expected output:

```
Key                      Value
---                      -----
db_name                  workshop-postgres
default_ttl              15m
max_ttl                  1h
creation_statements      CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE uc1_reader;
revocation_statements    DROP ROLE IF EXISTS "{{name}}";
```

The 15-minute TTL means each Postgres credential issued to the agent is valid for exactly 15 minutes. After expiry, Vault executes the `revocation_statements` to drop the dynamically created role from Postgres automatically.

:::expand{header="Agent Developer Track — hvac login flow and token vs credential TTL"}

When the agent calls `VaultClient.login()` at pod startup, the following exchange occurs:

```
Agent → Vault:  POST /v1/auth/kubernetes/login
                Body: { "role": "uc1", "jwt": "<SA-token>" }

Vault → EKS:    POST /apis/authentication.k8s.io/v1/tokenreviews
                Body: { "spec": { "token": "<SA-token>" } }

EKS → Vault:    { "status": { "authenticated": true,
                               "user": { "username": "system:serviceaccount:uc1:uc1-retriever-sa" } } }

Vault → Agent:  { "auth": { "client_token": "<vault-token>",
                              "policies": ["uc1-readonly"],
                              "lease_duration": 3600 } }
```

The returned `client_token` has a TTL of **1 hour** (the Vault token TTL, set on the Kubernetes auth role).

When the agent then calls `client.secrets.database.generate_credentials("uc1-readonly")`, a **separate** JIT credential is issued with a TTL of **15 minutes** (set on the database secrets engine role). These are two different TTL clocks:

| Entity | TTL | What it controls |
|---|---|---|
| Vault token (`client_token`) | 1 hour | How long the agent can make Vault API calls before needing to re-authenticate |
| Postgres JIT credential | 15 minutes | How long the specific `username`/`password` pair is valid for Postgres connections |

The agent refreshes JIT credentials on each incoming HTTP request — not when the Vault token expires. This means you see a new Vault audit log entry for each `/query` call.
:::

:::expand{header="Platform/Security Track — Kubernetes auth trust chain diagram"}

The Kubernetes auth trust chain has four participants:

```
┌─────────────────────┐    1. POST /v1/auth/kubernetes/login     ┌─────────────────────┐
│   UC1 Agent Pod     │  ──────────────────────────────────────► │   Vault (vault-0)   │
│  (uc1-retriever-sa) │    jwt = SA token from                   │                     │
└─────────────────────┘    /var/run/secrets/kubernetes.io/       │  2. TokenReview API │
                           serviceaccount/token                   │     call to EKS     │
                                                                  └──────────┬──────────┘
                                                                             │
                                                                             ▼
                                                                  ┌─────────────────────┐
                                                                  │   EKS TokenReview   │
                                                                  │   API               │
                                                                  │                     │
                                                                  │  Validates JWT sig  │
                                                                  │  against OIDC keys  │
                                                                  └──────────┬──────────┘
                                                                             │
                                              3. TokenReview response:      │
                                              authenticated=true            │
                                              user=system:serviceaccount:   │
                                                    uc1:uc1-retriever-sa    │
                                                                             ▼
                                                                  ┌─────────────────────┐
                                                                  │  Vault role lookup  │
                                                                  │                     │
                                                                  │  bound_sa_names =   │
                                                                  │   [uc1-retriever-sa]│
                                                                  │  bound_namespaces = │
                                                                  │   [uc1]             │
                                                                  │  → grant token with │
                                                                  │    uc1-readonly     │
                                                                  └─────────────────────┘
```

Steps 1–3 happen inside the cluster. The EKS TokenReview API endpoint is the **trust anchor** — Vault trusts whatever EKS says about the SA JWT. This is why:

- There is no Vault credential pre-seeded in the pod — the SA JWT IS the credential.
- Renaming the SA in Kubernetes without updating `bound_service_account_names` in Vault immediately breaks authentication — the binding is strict.
- The NetworkPolicy allows 8200/TCP to Vault from the `uc1` namespace — without this rule the login POST cannot reach Vault.
:::
