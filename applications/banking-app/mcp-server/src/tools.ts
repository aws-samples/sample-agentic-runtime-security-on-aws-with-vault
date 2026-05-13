/**
 * tools.ts — MCP tool implementations for UC2 personalized banking.
 *
 * Each tool follows this security-critical sequence:
 *   1. Extract sub claim from the user JWT (base64-decode payload segment).
 *   2. Call loginJwt(jwt) to get a per-user-scoped Vault token.
 *   3. Call getDbCreds(token) to get ephemeral PostgreSQL credentials.
 *   4. Create a pg.Client with Vault-vended credentials.
 *   5. Issue SET app.current_user_sub = '<sub>' on the connection.
 *      CRITICAL: This activates PostgreSQL RLS policies. Without it,
 *      current_setting('app.current_user_sub', true) returns NULL and RLS
 *      filters out ALL rows — queries return empty results.
 *   6. Run the SELECT query.
 *   7. Return results + credential metadata for OBJ-5 audit correlation.
 *
 * The agent never sees DB credentials. Only JWTs cross the agent→MCP boundary.
 */

import { Client as PgClient } from 'pg';
import { loginJwt, getDbCreds, type DbCredentials } from './vault-client.js';

const DB_HOST = process.env.RDS_ADDRESS ?? process.env.DB_HOST ?? 'localhost';
const DB_PORT = parseInt(process.env.RDS_PORT ?? process.env.DB_PORT ?? '5432', 10);
const DB_NAME = process.env.RDS_DB_NAME ?? process.env.DB_NAME ?? 'workshop';

/**
 * Extract the sub claim from a JWT without verifying its signature.
 *
 * Vault already validated the JWT during loginJwt() — we only need the
 * sub claim to set the PostgreSQL session variable for RLS enforcement.
 *
 * @param jwt - Raw JWT string (header.payload.signature)
 * @returns sub claim value
 */
function extractSubFromJwt(jwt: string): string {
  const parts = jwt.split('.');
  if (parts.length !== 3) {
    throw new Error('Invalid JWT format: expected header.payload.signature');
  }

  // Pad base64url to standard base64
  const payload = parts[1];
  const padded = payload + '='.repeat((4 - (payload.length % 4)) % 4);
  const decoded = Buffer.from(padded, 'base64url').toString('utf-8');

  let claims: Record<string, unknown>;
  try {
    claims = JSON.parse(decoded) as Record<string, unknown>;
  } catch {
    throw new Error('Failed to parse JWT payload as JSON');
  }

  const sub = claims['sub'];
  if (typeof sub !== 'string' || !sub) {
    throw new Error('JWT payload missing or empty sub claim');
  }

  return sub;
}

/**
 * Build a pg.Client authenticated with Vault-vended credentials and
 * activate PostgreSQL RLS by setting app.current_user_sub on the connection.
 *
 * Returns { client, creds } — caller is responsible for calling client.end().
 */
async function buildRlsClient(jwt: string): Promise<{ client: PgClient; creds: DbCredentials; sub: string }> {
  const sub = extractSubFromJwt(jwt);

  // Step 1: Exchange user JWT for per-user Vault token
  const vaultToken = await loginJwt(jwt);

  // Step 2: Get ephemeral DB credentials from Vault
  const creds = await getDbCreds(vaultToken);

  // Step 3: Create pg client with Vault-vended credentials
  const client = new PgClient({
    host: DB_HOST,
    port: DB_PORT,
    database: DB_NAME,
    user: creds.username,
    password: creds.password,
    ssl: { rejectUnauthorized: false },
  });

  await client.connect();

  // Step 4: CRITICAL — activate PostgreSQL Row-Level Security.
  // RLS policies use current_setting('app.current_user_sub', true) to filter rows.
  // Without this SET, current_setting() returns NULL and all rows are filtered out.
  await client.query(`SELECT set_config('app.current_user_sub', $1, false)`, [sub]);

  return { client, creds, sub };
}

/**
 * get_accounts — Retrieve bank accounts visible to the authenticated user.
 *
 * Vault jwt auth + RLS ensures only rows belonging to this user's sub are returned.
 */
export async function getAccounts(jwt: string): Promise<object> {
  const { client, creds, sub } = await buildRlsClient(jwt);

  try {
    const result = await client.query(
      `SELECT id, account_number, account_type, balance, currency
       FROM accounts
       ORDER BY account_type`
    );

    return {
      accounts: result.rows,
      credential_metadata: {
        vault_authenticated: true,
        vault_role: 'uc2-jwt',
        db_role: 'uc2-personal-readonly',
        lease_id: creds.leaseId,
        lease_duration_seconds: creds.leaseDuration,
        user_sub: sub,
      },
    };
  } finally {
    await client.end();
  }
}

/**
 * get_transactions — Retrieve recent transactions for the authenticated user.
 *
 * Vault jwt auth + RLS ensures only transactions belonging to this user's accounts
 * are returned. Optional account_id parameter filters to a single account.
 */
export async function getTransactions(jwt: string, accountId?: string): Promise<object> {
  const { client, creds, sub } = await buildRlsClient(jwt);

  try {
    let query: string;
    let params: string[];

    if (accountId) {
      query = `SELECT t.id, t.account_id, t.amount, t.description,
                      t.transaction_type, t.merchant, t.category, t.created_at
               FROM transactions t
               JOIN accounts a ON t.account_id = a.id
               WHERE t.account_id = $1
               ORDER BY t.created_at DESC
               LIMIT 50`;
      params = [accountId];
    } else {
      query = `SELECT t.id, t.account_id, t.amount, t.description,
                      t.transaction_type, t.merchant, t.category, t.created_at
               FROM transactions t
               JOIN accounts a ON t.account_id = a.id
               ORDER BY t.created_at DESC
               LIMIT 50`;
      params = [];
    }

    const result = await client.query(query, params);

    return {
      transactions: result.rows,
      credential_metadata: {
        vault_authenticated: true,
        vault_role: 'uc2-jwt',
        db_role: 'uc2-personal-readonly',
        lease_id: creds.leaseId,
        lease_duration_seconds: creds.leaseDuration,
        user_sub: sub,
      },
    };
  } finally {
    await client.end();
  }
}
