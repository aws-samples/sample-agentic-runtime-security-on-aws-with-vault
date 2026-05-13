/**
 * auth.ts — OIDC + ROPC authentication utilities for UC2.
 *
 * Primary flow: ROPC (Resource Owner Password Credentials) via a self-hosted
 * login form. IVIA OIDC Provider is "authorization only" — it has no built-in
 * login form. PKCE requires WebSEAL or an external IdP to present the form,
 * which is not available in this workshop environment. ROPC with a self-hosted
 * login form is the canonical IBM pattern (validated by ibm-verify-login
 * reference implementation).
 *
 * ROPC flow:
 *   1. User submits username + password on the landing page form.
 *   2. SvelteKit /login action calls passwordGrant() — POSTs grant_type=password
 *      to IVIA /oauth2/token with client_id + client_secret.
 *   3. IVIA authenticates the user against Simple AD (LDAP).
 *   4. On success, IVIA returns access_token + id_token.
 *   5. /login action sets httpOnly cookies and redirects to /dashboard.
 *
 * PKCE functions (buildUserManager, startLogin, handleCallback) are retained
 * as the production upgrade path — when WebSEAL or an external IdP provides
 * the IVIA login form, the PKCE flow can replace ROPC without changes to the
 * rest of the application.
 *
 * Environment variables:
 *   Server-side ($env/dynamic/private):
 *     IVIA_ISSUER        — IVIA issuer URL (ALB endpoint, e.g. http://<alb-hostname>)
 *     IVIA_CLIENT_ID     — OAuth client ID (default: agent-uc2)
 *     IVIA_CLIENT_SECRET — OAuth client secret (set in banking-ui ConfigMap)
 *   Client-side ($env/dynamic/public — used by PKCE fallback):
 *     PUBLIC_IVIA_ISSUER      — same as IVIA_ISSUER
 *     PUBLIC_IVIA_CLIENT_ID   — same as IVIA_CLIENT_ID
 *     PUBLIC_REDIRECT_URI     — full callback URL
 *     PUBLIC_AGENT_URL        — banking agent endpoint
 */

// ── PKCE imports (production upgrade path) ────────────────────────────────────
import { env } from '$env/dynamic/public';
import { UserManager, WebStorageStateStore } from 'oidc-client-ts';

// ── Error class ───────────────────────────────────────────────────────────────

/**
 * IBMVerifyError — thrown when the IVIA token endpoint returns a non-2xx
 * response. Includes the HTTP status code and the parsed response body for
 * structured error logging.
 *
 * Ported from ibm-verify-login reference implementation.
 */
export class IBMVerifyError extends Error {
  status: number;
  body: unknown;

  constructor(message: string, status: number, body: unknown) {
    super(message);
    this.name = 'IBMVerifyError';
    this.status = status;
    this.body = body;
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/**
 * postForm — POST application/x-www-form-urlencoded, parse JSON response.
 * Throws IBMVerifyError on non-2xx responses.
 *
 * Server-side only (called from +page.server.ts actions).
 * Ported from ibm-verify-login reference implementation.
 */
async function postForm(url: string, params: Record<string, string>): Promise<unknown> {
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json'
    },
    body: new URLSearchParams(params).toString()
  });

  let body: unknown;
  const contentType = res.headers.get('content-type') ?? '';
  if (contentType.includes('application/json')) {
    body = await res.json();
  } else {
    body = await res.text();
  }

  if (!res.ok) {
    throw new IBMVerifyError(
      `IBM Verify request failed: ${res.status} ${res.statusText}`,
      res.status,
      body
    );
  }

  return body;
}

// ── Token response shape ──────────────────────────────────────────────────────

export interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  scope?: string;
  id_token?: string;
  refresh_token?: string;
}

// ── ROPC: passwordGrant ───────────────────────────────────────────────────────

interface PasswordGrantParams {
  clientId: string;
  clientSecret: string;
  username: string;
  password: string;
  scope?: string;
}

/**
 * passwordGrant — Resource Owner Password Credentials grant.
 *
 * POSTs grant_type=password to the IVIA /oauth2/token endpoint.
 * IVIA authenticates the user against Simple AD (LDAP) and returns
 * access_token + id_token on success.
 *
 * Server-side only — never call from browser code.
 * Ported from ibm-verify-login reference implementation (lines 98-111).
 *
 * @param baseUri  IVIA issuer URL (e.g. http://<alb-hostname>)
 * @param params   clientId, clientSecret, username, password, scope
 */
export async function passwordGrant(
  baseUri: string,
  params: PasswordGrantParams
): Promise<TokenResponse> {
  const url = `${baseUri}/oauth2/token`;
  return postForm(url, {
    grant_type: 'password',
    client_id: params.clientId,
    client_secret: params.clientSecret,
    username: params.username,
    password: params.password,
    ...(params.scope ? { scope: params.scope } : {})
  }) as Promise<TokenResponse>;
}

// ── PKCE: production upgrade path ─────────────────────────────────────────────

/**
 * buildUserManager — UserManager for Authorization Code + PKCE flow.
 *
 * Production upgrade path: replace ROPC when WebSEAL or an external
 * IdP provides the IVIA login form. No changes needed to the rest of
 * the application — swap the /login action to call startLogin() instead.
 */
export function buildUserManager(): UserManager {
  const issuer = env.PUBLIC_IVIA_ISSUER ?? '';
  const clientId = env.PUBLIC_IVIA_CLIENT_ID ?? 'agent-uc2';
  const redirectUri = env.PUBLIC_REDIRECT_URI ?? '';

  if (!issuer || !redirectUri) {
    throw new Error('PUBLIC_IVIA_ISSUER and PUBLIC_REDIRECT_URI must be set');
  }

  return new UserManager({
    authority: issuer,
    client_id: clientId,
    redirect_uri: redirectUri,
    scope: 'openid profile email',
    response_type: 'code',
    response_mode: 'query',
    userStore: new WebStorageStateStore({
      store: typeof window !== 'undefined' ? window.sessionStorage : undefined
    }),
    automaticSilentRenew: false
  });
}

/**
 * startLogin — initiate Authorization Code + PKCE redirect to IVIA.
 */
export async function startLogin(userManager: UserManager): Promise<void> {
  await userManager.signinRedirect();
}

/**
 * handleCallback — complete the PKCE callback and return the access_token.
 */
export async function handleCallback(userManager: UserManager): Promise<string> {
  const user = await userManager.signinRedirectCallback();

  if (!user || !user.access_token) {
    throw new Error('OIDC callback failed: no access_token in response');
  }

  return user.access_token;
}

/**
 * getAgentUrl — returns the banking agent URL for client-side API calls.
 */
export function getAgentUrl(): string {
  return env.PUBLIC_AGENT_URL ?? '';
}
