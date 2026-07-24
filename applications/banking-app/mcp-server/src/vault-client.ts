/**
 * vault-client.ts — dynamic database credential vending via the Vault OAuth
 * resource server (Phase 9 native cutover, locked decision (b)).
 *
 * Security-critical path for UC2 personalized banking:
 *
 *   getDbCreds(jwt) — GET /v1/database/creds/uc2-personal-readonly presenting the
 *                     user IVIA OAuth JWT DIRECTLY as the X-Vault-Token header.
 *                     Vault's OAuth resource server validates the JWT (signature
 *                     via IVIA JWKS + jti) and returns ephemeral
 *                     { username, password } for the pg client.
 *
 * There is NO Vault login round-trip and NO intermediate Vault token — the user
 * OAuth JWT IS the credential. A jti claim is required (schema-validated by the
 * OAuth resource server); a vault:path_access RAR is NOT required (UC2 RAR is
 * optional per the locked decision). The token is presented only via the
 * X-Vault-Token header, never via an HTTP auth-scheme header (which silently
 * resolves to no identity). The credential fetch stays per-user request-scoped
 * — no shared token — satisfying OBJ-2: no standing DB credentials anywhere in
 * the request path.
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
 * Fetch per-user dynamic database credentials from the Vault database secrets engine
 * by presenting the user OAuth JWT directly as the Vault token.
 *
 * The user IVIA OAuth JWT is set as the `X-Vault-Token` header; Vault's OAuth
 * resource server validates it (signature via the IVIA JWKS endpoint + jti) and
 * authorizes the `database/creds/<role>` read per the user's identity. The dynamic
 * credentials are scoped by the Vault policy resolved from the JWT. PostgreSQL RLS
 * will further restrict rows to the calling user's sub claim.
 *
 * @param oauthJwt - User IVIA-issued OAuth JWT (raw JWT string, not a prefixed header value)
 * @param role     - Vault database role (default: uc2-personal-readonly)
 * @returns Ephemeral { username, password } valid for one connection, plus lease metadata
 */
export async function getDbCreds(
  oauthJwt: string,
  role: string = 'uc2-personal-readonly'
): Promise<DbCredentials> {
  const url = `${VAULT_ADDR}/v1/database/creds/${role}`;

  const res = await fetch(url, {
    method: 'GET',
    headers: { 'X-Vault-Token': oauthJwt },
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
