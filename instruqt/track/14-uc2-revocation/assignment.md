---
slug: uc2-revocation
type: challenge
title: Use Case 2 — Credential Revocation
teaser: Issue, observe, revoke; prove the Postgres role and Vault lease are both gone.
tabs:
  - title: Terminal
    type: terminal
    hostname: shell
---

The production code path for credential revocation is
`POST /v1/sys/leases/revoke` against Vault. An MCP server, banking agent, or
any session-end handler calls that endpoint when a session terminates. In this
challenge you exercise the same API directly via the `vault lease revoke` CLI.

## Walk it manually (optional)

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)

# Step 1: issue a credential and capture the lease id
CREDS_JSON=$(kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read database/creds/uc2-personal-readonly -format=json")
LEASE_ID=$(echo "$CREDS_JSON" | jq -r .lease_id)
PG_USER=$(echo "$CREDS_JSON" | jq -r .data.username)
echo "LEASE_ID=${LEASE_ID}"
echo "PG_USER=${PG_USER}"

# Step 2: confirm the Postgres role exists (master-creds query)
# (see workshop/content/60-use-case-2/65-credential-revocation for the full
# query — this challenge's check-shell does the same assertion automatically)

# Step 3: revoke the lease
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault lease revoke '${LEASE_ID}'"

# Step 4: confirm the lease is gone from active-leases
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault list -format=json sys/leases/lookup/database/creds/uc2-personal-readonly" \
  | jq -e --arg L "${LEASE_ID##*/}" '. | index($L) == null' \
  && echo "OK: lease removed from active list"
```

## Or just let the check-shell do it

The `check-shell` performs the issue → confirm → revoke → re-confirm cycle
end-to-end and asserts that:

1. The Vault lease was active immediately after issuance.
2. After `vault lease revoke`, the lease no longer appears in
   `sys/leases/lookup/database/creds/uc2-personal-readonly`.
3. The Postgres role created by the dynamic secrets engine is gone (looked up
   in `pg_roles` via the RDS master credentials pulled from AWS Secrets
   Manager).

When the check passes, advance to Use Case 3.
