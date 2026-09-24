# banking-mcp-server

Express server exposing an MCP endpoint for the UC2 banking agent. Receives agent tool calls carrying the user's IVIA OAuth JWT on the `Authorization: Bearer` header, presents that JWT **directly to Vault as the `X-Vault-Token` header** (Phase 9 native cutover — no `jwt_login` round-trip, no intermediate Vault token), obtains per-user-scoped PostgreSQL credentials, and queries RDS with Row-Level Security.

## Endpoints

| Method | Path      | Description                                    |
|--------|-----------|------------------------------------------------|
| GET    | `/health` | Liveness probe for Kubernetes                  |
| POST   | `/mcp`    | MCP tool dispatch — receives agent tool calls  |

## Tools

- **get_accounts** — Retrieve bank accounts for the authenticated user.
- **get_transactions** — Retrieve recent transactions, optionally filtered by `account_id`.

Neither tool takes a `jwt` parameter. The JWT is read from the request's `Authorization: Bearer` header and nowhere else, so the token the server authenticates is the token it acts on. The server sets that JWT as the `X-Vault-Token` header on the Vault request (`vault-client.ts` — the OAuth resource server profile validates it via its synthetic mount accessor + issuer-bound subject alias; `Authorization: Bearer` is NOT used because Bearer silently resolves to no identity). Vault returns short-lived PostgreSQL credentials scoped to the user's `sub` claim, and the server executes the query with RLS enforced.

The former `auth/jwt/login` round-trip is retired: there is no intermediate Vault token — the IVIA OAuth JWT authorizes each Vault call directly. UC2's registration uses `optional_authorization_details=true` (RAR optional). See `infrastructure/modules/vault_config/README.md` for the OAuth resource server profile and Agent Registry model.

## Known Issue: MCP SDK Singleton Bug (v1.10.x)

**Severity:** Critical — causes `Error: Already connected to a transport` on the second concurrent request, breaking all MCP tool calls after the first.

**Root cause:** The `@modelcontextprotocol/sdk` `McpServer` class binds to a single `StreamableHTTPServerTransport` via `connect()`. Once connected, calling `connect()` again throws. The original code created one `McpServer` at module scope and reused it across all incoming HTTP requests:

```typescript
// ❌ BROKEN — singleton pattern
const server = new McpServer({ name: 'banking-tools', version: '1.0.0' });
server.registerTool('get_accounts', ...);
server.registerTool('get_transactions', ...);

app.post('/mcp', async (req, res) => {
  const transport = new StreamableHTTPServerTransport({ ... });
  await server.connect(transport);  // 💥 throws on 2nd request
  await transport.handleRequest(req, res, req.body);
});
```

The first request succeeds. Every subsequent request fails because the singleton `McpServer` is already bound to the first transport.

**Fix:** Create a new `McpServer` + `StreamableHTTPServerTransport` per request (stateless mode). Clean up both on response close:

```typescript
// ✅ FIXED — per-request factory pattern
function createMcpServer(): McpServer {
  const server = new McpServer({ name: 'banking-tools', version: '1.0.0' });
  server.registerTool('get_accounts', ...);
  server.registerTool('get_transactions', ...);
  return server;
}

app.post('/mcp', async (req, res) => {
  const server = createMcpServer();
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,   // stateless
    enableJsonResponse: true,
  });

  res.on('close', () => {
    transport.close();
    server.close();
  });

  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});
```

This matches the official SDK example (`simpleStatelessStreamableHttp.ts` in `@modelcontextprotocol/sdk`). The per-request overhead is negligible — `McpServer` construction and tool registration are synchronous in-memory operations.

**References:**
- SDK source: `@modelcontextprotocol/sdk/server/mcp.js` — `connect()` method
- Official example: `examples/servers/everything/simpleStatelessStreamableHttp.ts`

## Credential lifecycle

The database credential is fetched with the **user's** OAuth JWT (`X-Vault-Token`)
and revoked with the **server's own** identity: at startup-on-demand the server
performs a Vault Kubernetes auth login as `uc2-mcp-server-sa` (role `uc2`,
policies `default` and `uc2-personal`). `uc2-personal` grants `update` on
`sys/leases/revoke` and `read` on `auth/token/lookup-self`, nothing else. The
login is cached and reused until 60 seconds before its TTL ends; a 403 forces a
new one. Calls that need a login while one is already on its way to Vault wait
for that one instead of starting their own, so the two tool calls of a cold
turn make one login, not two. A failed login is not kept: the next call tries
again.

Every tool call ends by closing the Postgres connection and revoking its lease,
so the ephemeral role is dropped immediately rather than living out its TTL.
Revocation is best-effort: the query has already returned, so a failed revoke is
logged (`vault_lease_revoke_failed`) and the credential falls back to expiring on
its TTL — it never turns a successful query into an error. Once Vault has issued
the credential, a failure to connect or query still revokes it.

The close and the revoke both finish before the tool returns, so each response
reports what happened:

| Field | What it holds |
|---|---|
| `credential_metadata.vault_auth_header` | How the credential read authenticated: `X-Vault-Token`, carrying the caller's OAuth JWT, with no Vault login |
| `credential_metadata.db_role`, `vault_path` | The database role and the Vault path the credential came from (`database/creds/uc2-personal-readonly`) |
| `credential_metadata.lease_id`, `lease_duration_seconds` | The lease Vault issued and its duration |
| `credential_metadata.lease_expires_at` | When the lease ends unless it is revoked first (ISO 8601, UTC): the time this server received the credential plus `lease_duration`. Left out when Vault returns no lease duration |
| `credential_metadata.lease_revoked` | `true` only when Vault confirmed the revoke |
| `credential_metadata.vault_policies`, `vault_identity_policies` | The policies Vault attaches to the caller's token, from `auth/token/lookup-self` with the same header. Left out when Vault does not answer |
| `issued_db_credentials.username`, `.password` | The credential itself |
| `mcp_vault_token` | The server's own Vault token that the revoke presented: `token`, `auth_method` (`kubernetes`), `role`, `policies` (from the login response), `ttl_seconds`, `issued_at`, `logged_in_for_this_call`, `presented_to` (`sys/leases/revoke`). Left out when no login was obtained |
| `mcp_service_account_token` | The Kubernetes ServiceAccount token that login presented to Vault: `jwt`, `service_account` (`<namespace>/<name>` as Vault reported it), `role`, `logged_in_for_this_call`, `presented_to` (`auth/kubernetes/login`). Left out when no login was obtained |

There is no `vault_role`: the credential read involves no Vault auth role (the
`uc2-jwt` JWT role was retired with the native cutover). The two policy lists
are what `lookup-self` reports for the caller's token; they are not the
effective permission, which is also bounded by the agent's ceiling (resolved
from `act.sub`) and which `lookup-self` does not list. The `lookup-self` call
runs after the revoke, and its response is never logged, because its `id` field
is the token itself.

`issued_db_credentials`, `mcp_vault_token` and `mcp_service_account_token` are
returned so the workshop can show attendees every credential used during a
turn. The banking agent removes all three from the response before the model
sees the tool result and sends them only on the caller's own chat event stream.
The server never logs any of them.

The database credential belongs to one caller and one call. The other two do
not: they are the server's standing credentials, so every caller's stream shows
the same values while the server reuses its login. Whoever sees the Vault token
holds its policies (`default`, `uc2-personal`) until it expires — among other
things, they can revoke any lease whose id they know. Whoever sees the
ServiceAccount token can present it to Vault's Kubernetes login as role `uc2`
for a Vault token of their own, until the ServiceAccount token expires.
