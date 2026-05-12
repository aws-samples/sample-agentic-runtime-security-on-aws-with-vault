/**
 * vault-client.ts — Vault JWT auth + dynamic database credential vending.
 *
 * Security-critical path for UC2 personalized banking:
 *
 *   1. loginJwt(jwt)        — POST /v1/auth/jwt/login with user IVIA JWT
 *                              Returns a per-user-scoped Vault token.
 *   2. getDbCreds(token)    — GET  /v1/database/creds/uc2-personal-readonly
 *                              Returns ephemeral { username, password } for pg client.
 *
 * The MCP server (not the agent) holds Vault tokens — the agent only ever
 * sees user JWTs. This satisfies OBJ-2: no standing DB credentials anywhere
 * in the request path.
 */

import fetch from 'node-fetch';

const VAULT_ADDR = process.env.VAULT_ADDR ?? 'http://vault.vault.svc.cluster.local:8200';

export interface DbCredentials {
  username: string;
  password: string;
  leaseId: string;
  leaseDuration: number;
}

/**
 * Authenticate to Vault using an IVIA-issued user JWT.
 *
 * Vault jwt auth validates the JWT signature against the IVIA JWKS endpoint
 * and resolves the bound policy associated with the uc2-jwt role.
 *
 * @param jwt   - IVIA-issued access token (Bearer payload, not "Bearer <token>")
 * @param role  - Vault jwt auth role (default: uc2-jwt)
 * @returns Vault client token scoped to the user's identity
 */
export async function loginJwt(jwt: string, role: string = 'uc2-jwt'): Promise<string> {
  const url = `${VAULT_ADDR}/v1/auth/jwt/login`;

  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jwt, role }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Vault JWT auth failed [${res.status}]: ${body}`);
  }

  const data = (await res.json()) as { auth?: { client_token?: string } };

  const token = data?.auth?.client_token;
  if (!token) {
    throw new Error('Vault JWT auth response missing auth.client_token');
  }

  return token;
}

/**
 * Fetch per-user dynamic database credentials from the Vault database secrets engine.
 *
 * The dynamic credentials are scoped by the Vault policy resolved during
 * loginJwt() — only paths that the user's JWT claims authorize are accessible.
 * PostgreSQL RLS will further restrict rows to the calling user's sub claim.
 *
 * @param vaultToken  - Client token returned from loginJwt()
 * @param role        - Vault database role (default: uc2-personal-readonly)
 * @returns Ephemeral { username, password } valid for one connection, plus lease metadata
 */
export async function getDbCreds(
  vaultToken: string,
  role: string = 'uc2-personal-readonly'
): Promise<DbCredentials> {
  const url = `${VAULT_ADDR}/v1/database/creds/${role}`;

  const res = await fetch(url, {
    method: 'GET',
    headers: { 'X-Vault-Token': vaultToken },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Vault DB creds fetch failed [${res.status}]: ${body}`);
  }

  const data = (await res.json()) as {
    data?: { username?: string; password?: string };
    lease_id?: string;
    lease_duration?: number;
  };

  const username = data?.data?.username;
  const password = data?.data?.password;

  if (!username || !password) {
    throw new Error('Vault DB creds response missing data.username or data.password');
  }

  return {
    username,
    password,
    leaseId: data.lease_id ?? 'unknown',
    leaseDuration: data.lease_duration ?? 0,
  };
}
