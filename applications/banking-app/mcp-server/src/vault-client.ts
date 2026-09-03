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
 * revokeLease(leaseId) — POST /v1/sys/leases/revoke using the MCP SERVER's OWN
 *                     Vault identity, obtained by Kubernetes auth login with its
 *                     uc2-mcp-server-sa ServiceAccount token. Revoking is a
 *                     workload action, not something the caller delegates, so it
 *                     deliberately does NOT reuse the user's OAuth JWT — that
 *                     would mean widening the user/agent envelope to include
 *                     lease revocation.
 *
 * There is NO Vault login round-trip on the CREDENTIAL path and NO intermediate
 * Vault token there — the user OAuth JWT IS the credential. A jti claim is required (schema-validated by the
 * OAuth resource server); a vault:path_access RAR is NOT required (UC2 RAR is
 * optional per the locked decision). The token is presented only via the
 * X-Vault-Token header, never via an HTTP auth-scheme header (which silently
 * resolves to no identity). The credential fetch stays per-user request-scoped
 * — no shared token — satisfying OBJ-2: no standing DB credentials anywhere in
 * the request path.
 */

import { readFile } from 'node:fs/promises';
import fetch from 'node-fetch';

const VAULT_ADDR = process.env.VAULT_ADDR ?? 'http://vault.vault.svc.cluster.local:8200';

// Kubernetes auth role this workload logs in as. Bound in Vault to
// uc2-mcp-server-sa in the banking-app namespace, so only this pod's projected
// ServiceAccount token can obtain it. Not a user identity — a workload role name.
const VAULT_K8S_ROLE = process.env.VAULT_K8S_ROLE ?? 'uc2';
const SA_TOKEN_PATH = '/var/run/secrets/kubernetes.io/serviceaccount/token';

// Cached service token from the Kubernetes login. Re-obtained when it is missing
// or within the renewal margin of expiry; a 403 also forces a fresh login, so an
// early revocation on Vault's side cannot wedge the server into a dead token.
let serviceToken: string | null = null;
let serviceTokenExpiresAt = 0;
const RENEW_MARGIN_MS = 60_000;

/**
 * Log in to Vault with this pod's Kubernetes ServiceAccount token and cache the
 * resulting service token.
 *
 * This is the MCP server's OWN identity — distinct from the user OAuth JWT that
 * authorises the credential fetch. Vault resolves it to the uc2-personal policy,
 * whose only capability is revoking leases.
 */
async function vaultK8sLogin(): Promise<string> {
  const saToken = (await readFile(SA_TOKEN_PATH, 'utf8')).trim();

  const res = await fetch(`${VAULT_ADDR}/v1/auth/kubernetes/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ role: VAULT_K8S_ROLE, jwt: saToken }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Vault kubernetes login failed [${res.status}]: ${body}`);
  }

  const data = (await res.json()) as {
    auth?: { client_token?: string; lease_duration?: number };
  };
  const token = data?.auth?.client_token;
  if (!token) {
    throw new Error('Vault kubernetes login returned no auth.client_token');
  }

  serviceToken = token;
  serviceTokenExpiresAt = Date.now() + (data.auth?.lease_duration ?? 0) * 1000;
  console.log(
    `vault_k8s_auth_success role=${VAULT_K8S_ROLE} ttl_seconds=${data.auth?.lease_duration ?? 0}`
  );
  return token;
}

async function getServiceToken(forceRefresh = false): Promise<string> {
  if (forceRefresh || !serviceToken || Date.now() > serviceTokenExpiresAt - RENEW_MARGIN_MS) {
    return vaultK8sLogin();
  }
  return serviceToken;
}

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

/**
 * Revoke a dynamic database credential the moment the work it was issued for is
 * done, rather than leaving it live until its TTL expires.
 *
 * Vault runs the role's revocation_statements immediately, so the ephemeral
 * Postgres role is dropped and any connection still holding it fails at its next
 * query. That is the whole point of a dynamic credential, and until this existed
 * nothing in the codebase ever called the revoke endpoint — the credential simply
 * aged out.
 *
 * Best-effort by design: the query has already succeeded and its results are the
 * caller's to keep, so a revoke failure is logged and swallowed rather than
 * turned into a user-visible error. The credential still expires on its TTL, so
 * a failure here degrades to the previous behaviour and never leaves the caller
 * with a broken response.
 *
 * @param leaseId - lease_id returned alongside the credentials by getDbCreds
 */
export async function revokeLease(leaseId: string): Promise<boolean> {
  if (!leaseId || leaseId === 'unknown') return false;

  const attempt = async (token: string) =>
    fetch(`${VAULT_ADDR}/v1/sys/leases/revoke`, {
      method: 'POST',
      headers: { 'X-Vault-Token': token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ lease_id: leaseId }),
    });

  try {
    let res = await attempt(await getServiceToken());
    // A 403 means the cached token is gone or was revoked out from under us —
    // log in again once before giving up.
    if (res.status === 403) {
      res = await attempt(await getServiceToken(true));
    }
    if (!res.ok) {
      const body = await res.text();
      console.error(`vault_lease_revoke_failed lease_id=${leaseId} status=${res.status} body=${body}`);
      return false;
    }
    console.log(`vault_lease_revoked lease_id=${leaseId}`);
    return true;
  } catch (err) {
    console.error(`vault_lease_revoke_error lease_id=${leaseId} error=${String(err)}`);
    return false;
  }
}
