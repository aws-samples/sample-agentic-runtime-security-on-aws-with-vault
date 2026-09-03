/**
 * index.ts — Express server exposing MCP endpoint for the UC2 banking agent.
 *
 * Endpoints:
 *   GET  /health  — liveness probe for Kubernetes
 *   POST /mcp     — MCP tool dispatch; the user JWT comes from the request's
 *                   Authorization: Bearer header and NOWHERE else.
 *
 * Each POST /mcp creates a fresh McpServer + transport (stateless mode).
 * The MCP SDK requires this — a single McpServer cannot be reused across
 * requests because connect() binds it to one transport at a time. That per-request
 * construction is what lets the authenticated JWT be closed over by the tool
 * handlers instead of travelling as a tool argument.
 *
 * The tools deliberately take NO jwt parameter. Use Case 2's whole claim is that
 * Vault sees the caller's real identity; if the acted-on token came from the tool
 * arguments, the identity Vault saw would be whatever the caller put in the
 * payload, and the Authorization header would constrain nothing.
 */

import express, { Request, Response } from 'express';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { z } from 'zod';
import { getAccounts, getTransactions } from './tools.js';

const app = express();
app.use(express.json());

// ---------------------------------------------------------------------------
// Health endpoint
// ---------------------------------------------------------------------------
app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', service: 'banking-mcp-server' });
});

// ---------------------------------------------------------------------------
// MCP Server factory — new instance per request (stateless mode)
// ---------------------------------------------------------------------------
function createMcpServer(authenticatedJwt: string): McpServer {
  const server = new McpServer({
    name: 'banking-tools',
    version: '1.0.0',
  });

  server.registerTool(
    'get_accounts',
    {
      title: 'Get Bank Accounts',
      description:
        'Retrieve bank accounts for the authenticated user. ' +
        'Vault JWT auth + PostgreSQL RLS ensures only the calling user\'s accounts are returned.',
      inputSchema: {},
    },
    async () => {
      try {
        console.log('get_accounts called');
        const data = await getAccounts(authenticatedJwt);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }],
        };
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        console.error('get_accounts error:', msg);
        return {
          content: [{ type: 'text' as const, text: `Error fetching accounts: ${msg}` }],
          isError: true,
        };
      }
    }
  );

  server.registerTool(
    'get_transactions',
    {
      title: 'Get Transactions',
      description:
        'Retrieve recent transactions for the authenticated user. ' +
        'Vault JWT auth + PostgreSQL RLS ensures only the calling user\'s transactions are returned. ' +
        'Optionally filter by account_id.',
      inputSchema: {
        account_id: z
          .string()
          .optional()
          .describe('Optional account ID to filter transactions to a single account'),
      },
    },
    // @ts-expect-error MCP SDK + Zod deep type instantiation
    async ({ account_id }: { account_id?: string }) => {
      try {
        console.log('get_transactions called', account_id ? `for account ${account_id}` : '(all accounts)');
        const data = await getTransactions(authenticatedJwt, account_id);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }],
        };
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        console.error('get_transactions error:', msg);
        return {
          content: [{ type: 'text' as const, text: `Error fetching transactions: ${msg}` }],
          isError: true,
        };
      }
    }
  );

  return server;
}

// ---------------------------------------------------------------------------
// MCP transport — Streamable HTTP (stateless, one server+transport per request)
// ---------------------------------------------------------------------------
app.post('/mcp', async (req: Request, res: Response) => {
  const authHeader = req.get('Authorization') ?? '';
  const jwt = authHeader.replace(/^Bearer\s+/i, '').trim();

  if (!jwt) {
    res.status(401).json({ error: 'Authorization header with Bearer JWT required' });
    return;
  }

  console.log('MCP request received');

  // The JWT the tools act on is the one this request authenticated with.
  const server = createMcpServer(jwt);
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });

  res.on('close', () => {
    transport.close();
    server.close();
  });

  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    console.error('MCP request error:', msg);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: '2.0',
        error: { code: -32603, message: 'Internal server error' },
        id: null,
      });
    }
  }
});

app.get('/mcp', (_req: Request, res: Response) => {
  res.status(405).set('Allow', 'POST').send('Method Not Allowed');
});

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------
const PORT = parseInt(process.env.MCP_PORT ?? '3001', 10);

app.listen(PORT, () => {
  console.log(`banking-mcp-server listening on port ${PORT}`);
  console.log(`VAULT_ADDR: ${process.env.VAULT_ADDR ?? 'http://vault.vault.svc.cluster.local:8200'}`);
  console.log(`DB_HOST:    ${process.env.RDS_ADDRESS ?? process.env.DB_HOST ?? 'localhost'}`);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received — shutting down');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT received — shutting down');
  process.exit(0);
});
