---
slug: uc1-vault-auth
id: yguipxwctyry
type: challenge
title: Use Case 1 — Vault Auth Inspection
teaser: Inspect the Vault role, policy, and database secrets engine that scope uc1-retriever-sa.
tabs:
- id: hz4gb8stxjjj
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
---

The Vault Kubernetes auth method, database secrets engine role, AWS secrets
engine role, and access policy for Use Case 1 were configured by the
`vault_config` Terraform module during tier-2 deploy. **You do not need to
reconfigure anything** — you inspect what is already there.

## Set up the Vault CLI

The Vault root token was written to `~/vault-init.json` during tier-2 init.
Load it and point the CLI at vault-0:

```bash
kubectl port-forward -n vault svc/vault 8200:8200 >/tmp/vault-pf.log 2>&1 &
sleep 2
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
vault status | grep -E 'Sealed|Initialized'
```

Expected: `Sealed: false`, `Initialized: true`.

## Step 1 — Inspect the Kubernetes auth role

```bash
vault read auth/kubernetes/role/uc1
```

Key observations:

- `bound_service_account_names = [uc1-retriever-sa]` — only this SA in
  namespace `uc1` can obtain this role.
- `policies = [uc1-readonly]` — the Vault token issued after login is scoped
  to this policy only.
- `token_ttl = 1h` — the Vault session lifetime (not the DB credential).

## Step 2 — Inspect the uc1-readonly policy

```bash
vault policy read uc1-readonly
```

Expected: a policy that grants `read` on `database/creds/uc1-readonly`,
`read,update` on `aws/sts/bedrock-reader`, plus the self-introspection
+ lease-renew paths. Notably absent: any Use Case 3 path, any `aws/iam/*`,
any `sys/mounts`.

## Step 3 — Inspect the database secrets engine role

```bash
vault read database/roles/uc1-readonly
```

Expected: `default_ttl = 15m`, `max_ttl = 1h`, and a `creation_statements`
block that creates a Postgres role with `GRANT SELECT` (no INSERT / UPDATE
/ DELETE / DDL).

## Step 4 — Issue a JIT credential to see the trust chain in action

Ask Vault to issue a database credential — the same call the agent makes:

```bash
vault read database/creds/uc1-readonly
```

You receive a fresh `{username, password, lease_id}` tuple with TTL 15 min.

When you're done, stop the port-forward:

```bash
kill %1
unset VAULT_TOKEN VAULT_ADDR
```
