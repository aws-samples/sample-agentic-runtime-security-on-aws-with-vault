---
title: 'Credential Revocation'
weight: 65
---

## Overview

In this module you observe the full credential lifecycle for a Use Case 2 session: active lease issuance, explicit revocation triggered by user logout, and the audit log event that records the revocation with the user's `sub` claim. This demonstrates how session end cascades from the browser to Vault to the Postgres role — no manual cleanup required.

## Step 1 — Establish a session and issue credentials

Log in to the Banking UI as Oscar. Navigate to the Accounts page to trigger at least one MCP Server tool call (which issues a DB credential via Vault). Then list the active leases for the `uc2-personal-readonly` credential path.

Listing active leases requires a Vault root token (the `uc2-personal` policy does not have `sys/leases/lookup` access — that path is reserved for admins to demonstrate the lifecycle without granting the MCP Server list-lease visibility):

```bash
# Set your Vault root token (from vault-init.sh output)
export VAULT_ROOT_TOKEN="<your-root-token>"

kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' \
  vault list sys/leases/lookup/database/creds/uc2-personal-readonly"
```

Expected output — at least one active lease:

```
Keys
----
v-jwt-uc2-personal-readonly-AbCd1234Ef56-1234567890
```

Note the lease ID. It encodes the role name and a timestamp. This lease corresponds to Oscar's current session.

To see the lease details (TTL countdown):

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' \
  vault lease lookup database/creds/uc2-personal-readonly/v-jwt-uc2-personal-readonly-AbCd1234Ef56-1234567890"
```

Expected output:

```
Key         Value
---         -----
expire_time  2026-05-12T10:30:00.000Z
issue_time   2026-05-12T10:15:00.000Z
last_renewal <nil>
ttl          14m59s
```

The `ttl` is counting down from 15 minutes. If no explicit revocation occurs, Vault will automatically revoke the credential at `expire_time` by dropping the ephemeral Postgres role.

## Step 2 — Find the corresponding Vault audit log entry

In a separate terminal, search the Vault audit log for the issuance event linked to this lease:

```bash
kubectl logs -n vault vault-0 --tail=100 \
  | grep '"type":"response"' \
  | jq 'select(.request.path == "database/creds/uc2-personal-readonly")' \
  | jq '{time: .time, lease_id: .response.data.lease_id, sub: .auth.metadata.sub}'
```

Expected output:

```json
{
  "time": "2026-05-12T10:15:00.123Z",
  "lease_id": "database/creds/uc2-personal-readonly/v-jwt-uc2-personal-readonly-AbCd1234Ef56-1234567890",
  "sub": "oscar"
}
```

The `sub` field confirms the issuance was tied to Oscar's user identity — extracted from the JWT during the `auth/jwt/login` step. This is OBJ-5 audit evidence: the audit log links user identity (`sub`) to the specific credential (`lease_id`) issued for that session.

## Step 3 — Log out (trigger credential revocation)

Click **Logout** in the Banking UI. The SvelteKit `/logout` server route:

1. Calls the Banking Agent's `POST /logout` endpoint with the session JWT.
2. The Banking Agent forwards the revocation request to the MCP Server.
3. The MCP Server calls `POST /v1/sys/leases/revoke` with the active lease ID and the Vault token from the session.
4. Vault revokes the lease and drops the ephemeral Postgres role.
5. The SvelteKit session is cleared.

## Step 4 — Confirm the lease is gone

After logout, re-run the lease list command:

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' \
  vault list sys/leases/lookup/database/creds/uc2-personal-readonly"
```

Expected output (after revocation):

```
No value found at sys/leases/lookup/database/creds/uc2-personal-readonly/
```

The lease list is empty. Oscar's ephemeral Postgres role no longer exists.

## Step 5 — Find the revocation event in the Vault audit log

```bash
kubectl logs -n vault vault-0 --tail=200 \
  | grep '"type":"response"' \
  | jq 'select(.request.path | startswith("sys/leases/revoke"))' \
  | jq '{time: .time, path: .request.path, revoked_lease: .request.data.lease_id}'
```

Expected output:

```json
{
  "time": "2026-05-12T10:22:34.567Z",
  "path": "sys/leases/revoke",
  "revoked_lease": "database/creds/uc2-personal-readonly/v-jwt-uc2-personal-readonly-AbCd1234Ef56-1234567890"
}
```

To correlate the revocation event back to Oscar's identity, join it with the earlier issuance entry using the `lease_id` as the join key. In Phase 6 this join is performed in Athena — here you can observe it manually:

- **Issuance entry** (Step 2): `lease_id = "...AbCd1234..."`, `sub = "oscar"`, `time = 10:15:00`
- **Revocation entry** (Step 5): `revoked_lease = "...AbCd1234..."`, `time = 10:22:34`

The same lease ID links both events. Duration: 7 minutes 34 seconds of active credential lifetime, then explicit revocation.

## Step 6 — Verify Postgres role is gone

The Vault dynamic secrets engine drops the Postgres role on revocation. Confirm it no longer exists:

```bash
RDS_HOST=$(kubectl get configmap uc2-mcp-config -n banking-app \
  -o jsonpath='{.data.RDS_HOST}')

kubectl exec -n banking-app deploy/banking-mcp-server -- \
  sh -c "PGPASSWORD='<admin_password>' psql -h ${RDS_HOST} -U vault_root -d workshop \
  -c \"SELECT rolname FROM pg_roles WHERE rolname LIKE 'v-jwt-uc2-personal-readonly-%';\""
```

Expected output:

```
 rolname
---------
(0 rows)
```

The ephemeral role is gone. Any session that was connected with that credential has been disconnected (the next query on the connection returns an authentication error).

:::expand{header="Platform Track — Vault lease lifecycle: TTL vs explicit revocation"}

Vault supports two credential termination paths:

| Path | Trigger | Audit log entry | Postgres role removal |
|---|---|---|---|
| TTL expiry | Vault's internal lease expiry timer fires | `lease_expired` event | Yes — Vault calls `DROP ROLE` |
| Explicit revocation | `POST /v1/sys/leases/revoke` | `sys/leases/revoke` response | Yes — immediate |

In Use Case 2 the explicit revocation path is used: the MCP Server calls Vault's revoke API when the user logs out. This is preferable to relying on TTL expiry because:

1. **Immediate effect**: The Postgres role is dropped within milliseconds of logout. A 15-minute TTL could leave a valid credential active for up to 15 minutes after the user session ends.
2. **Audit clarity**: The explicit revocation event in the Vault audit log records the exact time of session end — useful for security incident investigations.
3. **OBJ-5 completeness**: The audit trail has a defined start (jwt/login → creds issuance) and end (explicit revocation) — a complete session lifecycle record.

The TTL is still configured as a safety net: if the MCP Server crashes before issuing the revocation call, the credential automatically expires at `T+15m`. Defense-in-depth: revocation as first preference, TTL expiry as fallback.

Vault's dynamic secrets engine executes these Postgres statements on revocation:

```sql
-- On credential issuance (vault read database/creds/uc2-personal-readonly)
CREATE ROLE "v-jwt-uc2-personal-readonly-AbCd1234" 
  WITH LOGIN PASSWORD '<random>'
  VALID UNTIL '<now + 15m>'
  IN ROLE uc2_personal_readonly;

-- On revocation (explicit or TTL expiry)
REVOKE uc2_personal_readonly FROM "v-jwt-uc2-personal-readonly-AbCd1234";
DROP ROLE IF EXISTS "v-jwt-uc2-personal-readonly-AbCd1234";
```

The `REVOKE ... FROM` step removes the role membership (removing GRANTs) before the DROP — Postgres requires this ordering when the role owns objects via inheritance.
:::

:::expand{header="Agent Developer Track — How UI logout triggers Vault lease revocation"}

The logout flow traverses three services:

```
Browser: Click Logout
    ↓
SvelteKit /logout server route
  POST /api/logout → Banking Agent { jwt: "<session_jwt>", lease_id: "<lease_id>" }
    ↓
Banking Agent  POST /logout
  MCPClient.call_tool("revoke_credentials", { jwt, lease_id })
    ↓
MCP Server  handler: "revoke_credentials"
  // Re-authenticate to Vault to get a token with revoke capability
  const vaultToken = await vaultClient.loginWithK8sSa();  // k8s auth (workload identity)
  await fetch(`${VAULT_ADDR}/v1/sys/leases/revoke`, {
    method: 'POST',
    headers: { 'X-Vault-Token': vaultToken },
    body: JSON.stringify({ lease_id: params.lease_id }),
  });
    ↓
SvelteKit /logout server route
  session.destroy()
  redirect('/') 
```

Why does the MCP Server use k8s auth (not jwt auth) for the revocation call? The `uc2-personal` policy — which is what a `jwt/login` provides — grants `sys/leases/revoke` capability. However, using the workload identity (k8s auth) for the revocation call keeps the logout path independent of whether the user's JWT is still valid. If the JWT has expired before the user clicks logout (e.g., they left the tab open for hours), the k8s auth path still works. The MCP Server's `uc2-mcp-server-sa` Kubernetes ServiceAccount is always available as the workload identity credential.

The `lease_id` is stored in the SvelteKit server session (server-side, not in a cookie). The Banking UI server-side session tracks: `{ jwt, sub, lease_id }`. This state is set at the `/callback` route and cleared at `/logout`.
:::
