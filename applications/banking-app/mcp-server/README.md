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
policy `uc2-personal`), whose single capability is `sys/leases/revoke`.

Every tool call ends by closing the Postgres connection and revoking its lease,
so the ephemeral role is dropped immediately rather than living out its TTL.
Revocation is best-effort: the query has already returned, so a failed revoke is
logged (`vault_lease_revoke_failed`) and the credential falls back to expiring on
its TTL — it never turns a successful query into an error.
