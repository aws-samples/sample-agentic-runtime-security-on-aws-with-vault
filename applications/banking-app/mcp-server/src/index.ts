/**
 * index.ts — Express server exposing MCP endpoint for the UC2 banking agent.
 *
 * Endpoints:
 *   GET  /health  — liveness probe for Kubernetes
 *   POST /mcp     — MCP tool dispatch; receives agent tool calls with user JWT
 *
 * The server extracts the user JWT from the Authorization header on each
 * incoming request and passes it to the tool implementations in tools.ts.
 * No JWT is stored server-side — each request independently authenticates
 * to Vault and obtains ephemeral DB credentials (OBJ-2).
 *
 * MCP tools exposed:
 *   - get_accounts      — list user bank accounts (RLS-filtered)
 *   - get_transactions  — list recent transactions (RLS-filtered, optional account_id)
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
// MCP Server setup
// ---------------------------------------------------------------------------
const mcpServer = new McpServer({
  name: 'banking-tools',
  version: '1.0.0',
});

// Tool: get_accounts
mcpServer.registerTool(
  'get_accounts',
  {
    title: 'Get Bank Accounts',
    description:
      'Retrieve bank accounts for the authenticated user. ' +
      'Vault JWT auth + PostgreSQL RLS ensures only the calling user\'s accounts are returned.',
    inputSchema: {
      jwt: z.string().describe('IVIA-issued user JWT (access token, without "Bearer " prefix)'),
    },
  },
  async ({ jwt }: { jwt: string }) => {
    try {
      console.log('get_accounts called');
      const data = await getAccounts(jwt);
      return {
        content: [{ type: 'text' as const, text: 'Account data retrieved successfully' }],
        structuredContent: data,
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

// Tool: get_transactions
mcpServer.registerTool(
  'get_transactions',
  {
    title: 'Get Transactions',
    description:
      'Retrieve recent transactions for the authenticated user. ' +
      'Vault JWT auth + PostgreSQL RLS ensures only the calling user\'s transactions are returned. ' +
      'Optionally filter by account_id.',
    inputSchema: {
      jwt: z.string().describe('IVIA-issued user JWT (access token, without "Bearer " prefix)'),
      account_id: z
        .string()
        .optional()
        .describe('Optional account ID to filter transactions to a single account'),
    },
  },
  async ({ jwt, account_id }: { jwt: string; account_id?: string }) => {
    try {
      console.log('get_transactions called', account_id ? `for account ${account_id}` : '(all accounts)');
      const data = await getTransactions(jwt, account_id);
      return {
        content: [{ type: 'text' as const, text: 'Transaction data retrieved successfully' }],
        structuredContent: data,
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

// ---------------------------------------------------------------------------
// MCP transport — Streamable HTTP (stateless, one transport per request)
// ---------------------------------------------------------------------------
app.post('/mcp', async (req: Request, res: Response) => {
  const authHeader = req.get('Authorization') ?? '';
  const jwt = authHeader.replace(/^Bearer\s+/i, '').trim();

  if (!jwt) {
    res.status(401).json({ error: 'Authorization header with Bearer JWT required' });
    return;
  }

  console.log('MCP request received');

  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });

  try {
    await mcpServer.connect(transport);
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
  console.log(`DB_HOST:    ${process.env.DB_HOST ?? 'localhost'}`);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received — shutting down');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT received — shutting down');
  process.exit(0);
});
