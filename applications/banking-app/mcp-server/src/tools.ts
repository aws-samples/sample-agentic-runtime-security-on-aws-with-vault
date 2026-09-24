/**
 * tools.ts — MCP tool implementations for UC2 personalized banking.
 *
 * Each tool follows this security-critical sequence:
 *   1. Extract sub claim from the user JWT (base64-decode payload segment).
 *   2. Call getDbCreds(jwt) — presents the user OAuth JWT directly as the
 *      X-Vault-Token to fetch ephemeral PostgreSQL credentials (no login round-trip).
 *   3. Create a pg.Client with Vault-vended credentials.
 *   4. Issue SET app.current_user_sub = '<sub>' on the connection.
 *      CRITICAL: This activates PostgreSQL RLS policies. Without it,
 *      current_setting('app.current_user_sub', true) returns NULL and RLS
 *      filters out ALL rows — queries return empty results.
 *   5. Run the SELECT query.
 *   6. Close the connection AND revoke the Vault lease, so the ephemeral Postgres
 *      role is dropped now rather than lingering until its TTL expires. Steps 3-6
 *      share one guard: once Vault has issued the credential, a failure at any
 *      later step still revokes it.
 *   7. Ask Vault which policies it attaches to the caller's token
 *      (lookupCallerPolicies — auth/token/lookup-self, best-effort).
 *   8. Return results + credential metadata for OBJ-5 audit correlation, the
 *      revoke outcome (lease_revoked), the credential itself
 *      (issued_db_credentials), the MCP server's own Vault token that the
 *      revoke presented (mcp_vault_token), and the Kubernetes ServiceAccount
 *      token the server's Vault login presented (mcp_service_account_token).
 *
 * credential_metadata reports only what this code did or Vault returned: the
 * header the credential read authenticated with (the caller's OAuth JWT as
 * X-Vault-Token, no Vault login), the database role and path it read, the lease,
 * the revoke outcome, and the policies lookup-self reported. There is no Vault
 * auth role on this path — the uc2-jwt JWT role was retired with the native
 * cutover (infrastructure/modules/vault_config/main.tf) — so none is reported.
 *
 * Why the credential is returned: the workshop shows attendees, in full, every
 * credential issued during a turn (Bear, 2026-09-24). The agent takes
 * issued_db_credentials out of this response before anything reaches the model
 * and sends it only on its per-request event stream. By the time it is returned
 * the revoke has already run, and lease_revoked says whether Vault confirmed it.
 * mcp_vault_token and mcp_service_account_token travel the same way: the agent
 * takes them out and shows them only on the turn's event stream. They are the
 * server's standing credentials, reused across calls and callers until the
 * Vault token nears expiry. None of these is ever logged here.
 *
 * The jwt each tool receives is the one index.ts read from the request's
 * Authorization header — never a value taken from the tool arguments.
 */

import { Client as PgClient } from 'pg';
import {
  getDbCreds,
  lookupCallerPolicies,
  revokeLease,
  type CallerPolicies,
  type DbCredentials,
  type RevokeOutcome,
} from './vault-client.js';

const DB_HOST = process.env.RDS_ADDRESS ?? process.env.DB_HOST ?? 'localhost';
const DB_PORT = parseInt(process.env.RDS_PORT ?? process.env.DB_PORT ?? '5432', 10);
const DB_NAME = process.env.RDS_DB_NAME ?? process.env.DB_NAME ?? 'workshop';

/**
 * Extract the sub claim from a JWT without verifying its signature.
 *
 * Vault validates the JWT when it is presented as the X-Vault-Token on the
 * getDbCreds() call — we only need the sub claim here to set the PostgreSQL
 * session variable for RLS enforcement.
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

interface UserQueryResult {
  rows: Record<string, unknown>[];
  creds: DbCredentials;
  sub: string;
  revoke: RevokeOutcome;
  callerPolicies: CallerPolicies | null;
}

/**
 * Run one query as the calling user, with a database credential that exists
 * only for this query.
 *
 * Gets the credential from Vault, connects with it, activates PostgreSQL RLS by
 * setting app.current_user_sub, runs the query, then closes the connection and
 * revokes the lease — all before returning, so the revoke outcome is known.
 */
async function queryAsUser(jwt: string, sql: string, params: string[]): Promise<UserQueryResult> {
  const sub = extractSubFromJwt(jwt);

  // Get ephemeral DB credentials from Vault by presenting the user OAuth JWT
  // directly as the X-Vault-Token (no login round-trip).
  const creds = await getDbCreds(jwt);

  const client = new PgClient({
    host: DB_HOST,
    port: DB_PORT,
    database: DB_NAME,
    user: creds.username,
    password: creds.password,
    ssl: { rejectUnauthorized: false },
  });

  let rows: Record<string, unknown>[] = [];
  let revoke: RevokeOutcome = { revoked: false, serviceLogin: null, freshLogin: false };
  try {
    await client.connect();

    // CRITICAL — activate PostgreSQL Row-Level Security.
    // RLS policies use current_setting('app.current_user_sub', true) to filter rows.
    // Without this SET, current_setting() returns NULL and all rows are filtered out.
    await client.query(`SELECT set_config('app.current_user_sub', $1, false)`, [sub]);

    rows = (await client.query(sql, params)).rows;
  } finally {
    try {
      await client.end();
    } catch (err) {
      // Closing must never stand between the credential and its revoke.
      console.error(`pg_client_end_failed error=${err instanceof Error ? err.message : String(err)}`);
    }
    // The credential existed for exactly this query. Hand it back now.
    revoke = await revokeLease(creds.leaseId);
  }

  // After the revoke, so asking never extends the credential's life.
  const callerPolicies = await lookupCallerPolicies(jwt);

  return { rows, creds, sub, revoke, callerPolicies };
}

/**
 * What every tool returns besides its rows: the audit fields, the revoke
 * outcome, and the credential Vault issued (see the header for why).
 */
function credentialReport({ creds, sub, revoke, callerPolicies }: UserQueryResult): object {
  const login = revoke.serviceLogin;
  return {
    credential_metadata: {
      vault_authenticated: true,
      vault_auth_header: 'X-Vault-Token',
      db_role: creds.dbRole,
      vault_path: creds.vaultPath,
      lease_id: creds.leaseId,
      lease_duration_seconds: creds.leaseDuration,
      // When the credential stops working if the revoke did not happen.
      ...(creds.leaseExpiresAt ? { lease_expires_at: creds.leaseExpiresAt } : {}),
      lease_revoked: revoke.revoked,
      user_sub: sub,
      ...(callerPolicies
        ? {
            vault_policies: callerPolicies.policies,
            vault_identity_policies: callerPolicies.identityPolicies,
          }
        : {}),
    },
    issued_db_credentials: {
      username: creds.username,
      password: creds.password,
    },
    // The MCP server's own Vault token, from its Kubernetes login, that the
    // revoke presented. A sibling of credential_metadata, never inside it: the
    // agent narrates credential_metadata, and takes this out for its event
    // stream only. Absent when no login was obtained.
    ...(login
      ? {
          mcp_vault_token: {
            token: login.token,
            auth_method: 'kubernetes',
            role: login.role,
            policies: login.policies,
            ttl_seconds: login.ttlSeconds,
            issued_at: login.issuedAt,
            logged_in_for_this_call: revoke.freshLogin,
            presented_to: 'sys/leases/revoke',
          },
          // The Kubernetes ServiceAccount token that login presented to Vault.
          // Same handling as mcp_vault_token: a sibling, taken out by the agent
          // for its event stream only.
          mcp_service_account_token: {
            jwt: login.serviceAccountJwt,
            service_account: login.serviceAccount,
            role: login.role,
            logged_in_for_this_call: revoke.freshLogin,
            presented_to: 'auth/kubernetes/login',
          },
        }
      : {}),
  };
}

/**
 * get_accounts — Retrieve bank accounts visible to the authenticated user.
 *
 * The caller's OAuth JWT (X-Vault-Token) + RLS ensures only rows belonging to this
 * user's sub are returned.
 */
export async function getAccounts(jwt: string): Promise<object> {
  const result = await queryAsUser(
    jwt,
    `SELECT id, account_number, account_type, balance, currency
     FROM accounts
     ORDER BY account_type`,
    []
  );

  return {
    accounts: result.rows,
    ...credentialReport(result),
  };
}

/**
 * get_transactions — Retrieve recent transactions for the authenticated user.
 *
 * The caller's OAuth JWT (X-Vault-Token) + RLS ensures only transactions belonging to
 * this user's accounts are returned. Optional account_id parameter filters to a single account.
 */
export async function getTransactions(jwt: string, accountId?: string): Promise<object> {
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

  const result = await queryAsUser(jwt, query, params);

  return {
    transactions: result.rows,
    ...credentialReport(result),
  };
}
