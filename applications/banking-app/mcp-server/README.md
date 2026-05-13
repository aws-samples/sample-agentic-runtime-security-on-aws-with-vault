# banking-mcp-server

Express server exposing an MCP endpoint for the UC2 banking agent. Receives agent tool calls with the user's JWT, authenticates to Vault, obtains per-user-scoped PostgreSQL credentials, and queries RDS with Row-Level Security.

## Endpoints

| Method | Path      | Description                                    |
|--------|-----------|------------------------------------------------|
| GET    | `/health` | Liveness probe for Kubernetes                  |
| POST   | `/mcp`    | MCP tool dispatch — receives agent tool calls  |

## Tools

- **get_accounts** — Retrieve bank accounts for the authenticated user.
- **get_transactions** — Retrieve recent transactions, optionally filtered by `account_id`.

Both tools require a `jwt` parameter (IVIA-issued access token). The server authenticates to Vault using this JWT (`auth/jwt/login`), receives short-lived PostgreSQL credentials scoped to the user's `sub` claim, and executes the query with RLS enforced.

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
