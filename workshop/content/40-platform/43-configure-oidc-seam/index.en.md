---
title: 'Configure the OIDC Seam'
weight: 43
---

## Overview

In this step you configure the **OIDC seam** — the integration point where an IVIA-issued JWT becomes a Vault-vended dynamic credential. Two Terraform modules apply here: `vault_config` and `isva_config`.

`vault_config` configures Vault with:

- **Kubernetes auth method** — enables workloads with projected service-account tokens to authenticate as Vault entities.
- **JWT auth method** — trusts IVIA's OIDC discovery URL; binds user-scoped JWT claims to Vault policies.
- **Database secrets engine** — dynamic PostgreSQL credentials with three roles (read-only, read-write, audit).
- **AWS secrets engine** — dynamic IAM credentials for agents that need AWS API access.
- **Vault policies** — `uc1-agent-policy`, `uc2-agent-policy`, `uc3-agent-policy` scoped to each use case.
- **Audit device** — file-based audit log writing to `/vault/audit/vault-audit.log` inside the pod (mapped to a PVC, read by a log-shipper sidecar).

`isva_config` configures IVIA with:

- Three OAuth 2.0 clients (one per use case agent), each with CIBA support and a `may_act` claim for RFC 8693 delegation.
- CIBA authorization server policies mapped to the three clients.
- Rich Authorization Requests (RAR) type definitions (`credential-vend`, `data-query`, `audit-read`).
- JWT signing configuration aligned with Vault's `bound_issuer` setting.

## Step 1 — Set VAULT_TOKEN and VAULT_ADDR

The `vault_config` and `isva_config` modules need the Vault root token you saved in the previous module. Add these to the HCP Terraform workspace variable set:

| Variable | Value |
|---|---|
| `vault_token` | The root token from `~/vault-init.json` |
| `vault_addr` | `https://vault.vault.svc.cluster.local:8200` |

Or set them locally if running a manual workspace apply:

```bash
export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
export VAULT_ADDR="https://vault.vault.svc.cluster.local:8200"
```

## Step 2 — Run configure-workshop.sh

`vault_config` and `isva_config` are applied as part of the workspace run. After `vault` and `verify_access` are healthy (verified in the previous steps), run the post-deploy configuration script to complete Vault initialization and IVIA configuration:

```bash
bash infrastructure/scripts/configure-workshop.sh
```

This script calls `vault-configure.sh` (which wires up Vault auth methods, secrets engines, and policies) and `ivia-configure.sh` (which registers OAuth 2.0 clients).

In HCP Terraform UI, review the workspace run outputs. You will see Vault auth methods, secrets engines, roles, and policies being reported.

## Step 3 — What was configured

After apply completes, verify Vault auth methods:

```bash
kubectl exec -n vault vault-0 -- vault auth list
```

Expected output:

```
Path           Type          Accessor                Description
----           ----          --------                -----------
kubernetes/    kubernetes    auth_kubernetes_...     Kubernetes workload auth
jwt/           jwt           auth_jwt_...            IVIA OIDC user auth
token/         token         auth_token_...          token based credentials
```

Verify secrets engines:

```bash
kubectl exec -n vault vault-0 -- vault secrets list
```

Expected output:

```
Path          Type         Description
----          ----         -----------
aws/          aws          Dynamic IAM credentials
database/     database     Dynamic PostgreSQL credentials
sys/          system       system endpoints used for control, policy and debugging
```

Verify the JWT auth configuration points to IVIA:

```bash
kubectl exec -n vault vault-0 -- vault read auth/jwt/config
```

Expected output includes:

```
oidc_discovery_url    https://isvaop.verify-access.svc.cluster.local:8436/oauth2
bound_issuer          https://isvaop.verify-access.svc.cluster.local:8436/oauth2
```

Verify the database connection:

```bash
kubectl exec -n vault vault-0 -- vault read database/config/workshop-pg
```

Expected output shows the PostgreSQL connection URL. The `allowed_roles` field lists the three roles:

```
connection_details    map[username:vault_root ...]
allowed_roles         uc1-readonly, uc2-readwrite, uc3-audit
```

## Step 4 — Verify IVIA OAuth clients

From within the cluster, check the registered OAuth 2.0 clients:

```bash
kubectl exec -n vault vault-0 -- \
  curl -sk https://isvaop.verify-access.svc.cluster.local:8436/oauth2/clients \
  | jq '.[] | .client_id'
```

Expected output:

```
"uc1-strands-agent"
"uc2-strands-agent"
"uc3-strands-agent"
```

## What was configured — summary

| Module | Resource | Count |
|---|---|---|
| vault_config | Kubernetes auth method | 1 |
| vault_config | JWT auth method (IVIA OIDC) | 1 |
| vault_config | Database secrets engine | 1 |
| vault_config | Database roles | 3 (uc1-readonly, uc2-readwrite, uc3-audit) |
| vault_config | AWS secrets engine | 1 |
| vault_config | Vault policies | 3 (uc1/uc2/uc3) |
| vault_config | Audit device | 1 (file, PVC) |
| isva_config | OAuth 2.0 clients | 3 |
| isva_config | CIBA policies | 3 |
| isva_config | RAR type definitions | 3 (credential-vend, data-query, audit-read) |

## The OIDC seam — how it works at runtime

```
  Agent (uc1-strands-agent) obtains IVIA JWT via CIBA
         │
         ▼
  POST /v1/auth/jwt/login  { role=uc1-agent, jwt=<IVIA token> }
         │
  Vault verifies JWT signature against IVIA JWKS endpoint
  Vault checks bound_claims: { sub=<user>, aud=uc1-strands-agent }
         │
  Vault policy: uc1-agent-policy → allows database/creds/uc1-readonly
         │
         ▼
  Vault issues dynamic PostgreSQL credential (TTL 1h, renewable)
```

The `may_act` claim in the JWT (RFC 8693) binds the credential to the specific agent acting on behalf of the specific user. The `uc3-jwt` role additionally enforces `bound_claims.may_act=*` to ensure delegation is explicit.
