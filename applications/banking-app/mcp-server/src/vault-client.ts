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
 * lookupCallerPolicies(jwt) — GET /v1/auth/token/lookup-self with the same JWT as
 *                     the X-Vault-Token, so the tool can report the policies
 *                     Vault attaches to the caller's token. Read-only.
 *
 * revokeLease(leaseId) — POST /v1/sys/leases/revoke using the MCP SERVER's OWN
 *                     Vault identity, obtained by Kubernetes auth login with its
 *                     uc2-mcp-server-sa ServiceAccount token. Revoking is a
 *                     workload action, not something the caller delegates, so it
 *                     deliberately does NOT reuse the user's OAuth JWT — that
 *                     would mean widening the user/agent envelope to include
 *                     lease revocation. It returns that login with the revoke
 *                     outcome, so the turn can show the token it presented.
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

/**
 * The MCP server's own Vault login, as the Kubernetes auth login returned it.
 *
 * `token` is a live Vault token. It leaves this module only in RevokeOutcome, so
 * tools.ts can hand it to the agent for the turn's own event stream (the
 * workshop shows every credential in full). It is never logged.
 */
export interface ServiceLogin {
  /** auth.client_token — the Vault token revokeLease presents. */
  token: string;
  /** The Kubernetes auth role it logged in as. */
  role: string;
  /** auth.policies from the login response. */
  policies: string[];
  /** auth.lease_duration from the login response. */
  ttlSeconds: number;
  /** When this server received the login response (ISO 8601, UTC). */
  issuedAt: string;
}

// Cached service login from the Kubernetes auth method. Re-obtained when it is
// missing or within the renewal margin of expiry; a 403 also forces a fresh
// login, so an early revocation on Vault's side cannot wedge the server into a
// dead token.
let serviceLogin: ServiceLogin | null = null;
let serviceTokenExpiresAt = 0;
const RENEW_MARGIN_MS = 60_000;
// A login already on its way to Vault. Concurrent callers wait for it instead of
// starting their own, so a cold two-tool turn makes ONE login, not one per tool
// (each extra login is a live token nobody uses until it expires). Cleared once
// it settles, success or failure, so a failed login never blocks the next try.
let loginInFlight: Promise<ServiceLogin> | null = null;

/**
 * Log in to Vault with this pod's Kubernetes ServiceAccount token and cache the
 * resulting service login.
 *
 * This is the MCP server's OWN identity — distinct from the user OAuth JWT that
 * authorises the credential fetch. Vault resolves it to the uc2-personal policy,
 * whose only capability is revoking leases.
 */
async function vaultK8sLogin(): Promise<ServiceLogin> {
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
    auth?: { client_token?: string; lease_duration?: number; policies?: unknown };
  };
  const receivedAt = Date.now();
  const token = data?.auth?.client_token;
  if (!token) {
    throw new Error('Vault kubernetes login returned no auth.client_token');
  }

  const ttlSeconds = data.auth?.lease_duration ?? 0;
  const policies = Array.isArray(data.auth?.policies)
    ? data.auth.policies.filter((p): p is string => typeof p === 'string')
    : [];
  serviceLogin = {
    token,
    role: VAULT_K8S_ROLE,
    policies,
    ttlSeconds,
    issuedAt: new Date(receivedAt).toISOString(),
  };
  serviceTokenExpiresAt = receivedAt + ttlSeconds * 1000;
  console.log(`vault_k8s_auth_success role=${VAULT_K8S_ROLE} ttl_seconds=${ttlSeconds}`);
  return serviceLogin;
}

/**
 * The cached service login, or a new one; `fresh` says whether the login was
 * made while this call waited (by this call, or by a concurrent one it joined).
 *
 * A login already in flight is always joined — also on `forceRefresh`, since a
 * login that started after the cached token was last used is already the fresh
 * token a 403 retry needs.
 */
async function getServiceLogin(forceRefresh = false): Promise<{ login: ServiceLogin; fresh: boolean }> {
  if (loginInFlight) {
    return { login: await loginInFlight, fresh: true };
  }
  if (forceRefresh || !serviceLogin || Date.now() > serviceTokenExpiresAt - RENEW_MARGIN_MS) {
    const pending = vaultK8sLogin();
    loginInFlight = pending;
    try {
      return { login: await pending, fresh: true };
    } finally {
      if (loginInFlight === pending) loginInFlight = null;
    }
  }
  return { login: serviceLogin, fresh: false };
}

export interface DbCredentials {
  username: string;
  password: string;
  leaseId: string;
  leaseDuration: number;
  /** The Vault path the credential was read from, e.g. database/creds/uc2-personal-readonly. */
  vaultPath: string;
  /** The Vault database role in that path, e.g. uc2-personal-readonly. */
  dbRole: string;
  /**
   * When the lease ends unless it is revoked first (ISO 8601, UTC): the time
   * this server received the credential plus the lease_duration Vault returned.
   * Null when Vault returned no lease_duration.
   */
  leaseExpiresAt: string | null;
}

/** The policies Vault attaches to the caller's token, as auth/token/lookup-self reports them. */
export interface CallerPolicies {
  /** lookup-self data.policies */
  policies: string[];
  /** lookup-self data.identity_policies */
  identityPolicies: string[];
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
  const vaultPath = `database/creds/${role}`;
  const url = `${VAULT_ADDR}/v1/${vaultPath}`;

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
  const receivedAt = Date.now();

  const username = data?.data?.username;
  const password = data?.data?.password;

  if (!username || !password) {
    throw new Error('Vault DB creds response missing data.username or data.password');
  }

  const leaseDuration = data.lease_duration ?? 0;
  return {
    username,
    password,
    leaseId: data.lease_id ?? 'unknown',
    leaseDuration,
    vaultPath,
    dbRole: role,
    leaseExpiresAt: leaseDuration > 0 ? new Date(receivedAt + leaseDuration * 1000).toISOString() : null,
  };
}

/**
 * Ask Vault which policies it attaches to the caller's OAuth JWT, presented
 * exactly as getDbCreds presents it (X-Vault-Token). Read-only: GET
 * auth/token/lookup-self, which the Use Case 2 human baseline and agent ceiling
 * both grant.
 *
 * These are the policies as Vault labels them on the caller's token. They are
 * NOT the effective permission: that is also bounded by the agent's ceiling
 * (resolved from act.sub), which lookup-self does not list.
 *
 * Best-effort: any failure returns null and the tool still succeeds. Only the
 * two policy lists are read — the response's `id` field is the token itself, so
 * the body is never logged or returned.
 *
 * @param oauthJwt - User IVIA-issued OAuth JWT, the same one getDbCreds presented
 * @returns the token and identity policies, or null when Vault did not answer
 */
export async function lookupCallerPolicies(oauthJwt: string): Promise<CallerPolicies | null> {
  const names = (value: unknown): string[] =>
    Array.isArray(value) ? value.filter((p): p is string => typeof p === 'string') : [];

  try {
    const res = await fetch(`${VAULT_ADDR}/v1/auth/token/lookup-self`, {
      method: 'GET',
      headers: { 'X-Vault-Token': oauthJwt },
    });
    if (!res.ok) {
      console.error(`vault_lookup_self_failed status=${res.status}`);
      return null;
    }
    const body = (await res.json()) as { data?: { policies?: unknown; identity_policies?: unknown } };
    return {
      policies: names(body?.data?.policies),
      identityPolicies: names(body?.data?.identity_policies),
    };
  } catch (err) {
    console.error(`vault_lookup_self_error error=${err instanceof Error ? err.message : String(err)}`);
    return null;
  }
}

/** What revokeLease did: the outcome, and the MCP server's own login it presented. */
export interface RevokeOutcome {
  /** true only when Vault confirmed the revoke. */
  revoked: boolean;
  /** The login whose token the last revoke attempt presented; null when no login was obtained. */
  serviceLogin: ServiceLogin | null;
  /** true when that login was made during this call (none cached, near expiry, or the cached one got a 403). */
  freshLogin: boolean;
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
 * @returns whether Vault confirmed the revoke (tools.ts reports it to the agent
 *          as lease_revoked), and the service login whose token the revoke
 *          presented
 */
export async function revokeLease(leaseId: string): Promise<RevokeOutcome> {
  if (!leaseId || leaseId === 'unknown') return { revoked: false, serviceLogin: null, freshLogin: false };

  const attempt = async (token: string) =>
    fetch(`${VAULT_ADDR}/v1/sys/leases/revoke`, {
      method: 'POST',
      headers: { 'X-Vault-Token': token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ lease_id: leaseId }),
    });

  let used: { login: ServiceLogin; fresh: boolean } | null = null;
  const outcome = (revoked: boolean): RevokeOutcome => ({
    revoked,
    serviceLogin: used?.login ?? null,
    freshLogin: used?.fresh ?? false,
  });

  try {
    used = await getServiceLogin();
    let res = await attempt(used.login.token);
    // A 403 means the cached token is gone or was revoked out from under us —
    // log in again once before giving up.
    if (res.status === 403) {
      used = await getServiceLogin(true);
      res = await attempt(used.login.token);
    }
    if (!res.ok) {
      const body = await res.text();
      console.error(`vault_lease_revoke_failed lease_id=${leaseId} status=${res.status} body=${body}`);
      return outcome(false);
    }
    console.log(`vault_lease_revoked lease_id=${leaseId}`);
    return outcome(true);
  } catch (err) {
    console.error(`vault_lease_revoke_error lease_id=${leaseId} error=${String(err)}`);
    return outcome(false);
  }
}
