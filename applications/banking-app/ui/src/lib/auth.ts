/**
 * auth.ts — Server-side OAuth Authorization Code + PKCE helpers for UC2.
 *
 * Flow: banking-ui never renders a login form. When an unauthenticated user
 * lands on /, the server generates PKCE state and redirects the browser to
 * IVIA /oauth2/authorize. IVIA's reverse proxy (WebSEAL/WRP) intercepts
 * unauthenticated traffic and serves its own login form. After login, IVIA
 * issues an authorization code and redirects back to /callback, where the
 * code is exchanged for tokens server-to-server.
 *
 * Environment variables (all server-side, $env/dynamic/private):
 *   IVIA_ISSUER        — Public IVIA URL (ALB endpoint, ends in /isvaop).
 *                        Used for the browser-facing /authorize redirect.
 *   IVIA_BASE_URL      — In-cluster IVIA URL (https://iviaop.verify-access.
 *                        svc.cluster.local:8436). Used for the server-side
 *                        token exchange — bypasses the WRP ALB entirely.
 *   IVIA_CLIENT_ID     — OAuth client ID (default: agent-uc2).
 *   IVIA_CLIENT_SECRET — OAuth client secret (HTTP Basic auth on /token).
 *   REDIRECT_URI       — Full callback URL registered with IVIA.
 *
 * The agent-uc2 client is declared in clients.yml.tftpl with
 *   grant_types: [authorization_code, refresh_token]
 *   token_endpoint_auth_method: client_secret_basic
 *   require_pkce: true
 */

import { createHash, randomBytes } from 'node:crypto';

export interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  scope?: string;
  id_token?: string;
  refresh_token?: string;
}

export interface PkceState {
  codeVerifier: string;
  codeChallenge: string;
  state: string;
}

function base64UrlEncode(buf: Buffer): string {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * generatePkce — fresh PKCE pair + CSRF state for one authorize call.
 * Verifier is 64 bytes (96 base64url chars), challenge is S256(verifier).
 */
export function generatePkce(): PkceState {
  const codeVerifier = base64UrlEncode(randomBytes(64));
  const codeChallenge = base64UrlEncode(createHash('sha256').update(codeVerifier).digest());
  const state = base64UrlEncode(randomBytes(16));
  return { codeVerifier, codeChallenge, state };
}

/**
 * buildAuthorizeUrl — IVIA /oauth2/authorize URL the browser is redirected to.
 * Browser-facing, so uses IVIA_ISSUER (public ALB), not IVIA_BASE_URL.
 */
export function buildAuthorizeUrl(opts: {
  issuer: string;
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  state: string;
  scope?: string;
}): string {
  const params = new URLSearchParams({
    response_type: 'code',
    client_id: opts.clientId,
    redirect_uri: opts.redirectUri,
    code_challenge: opts.codeChallenge,
    code_challenge_method: 'S256',
    state: opts.state,
    scope: opts.scope ?? 'openid profile email'
  });
  return `${opts.issuer}/oauth2/authorize?${params.toString()}`;
}

/**
 * exchangeCodeForTokens — server-side authorization code exchange.
 * Uses IVIA_BASE_URL (cluster DNS) for direct iviaop pod access — the WRP
 * ALB is not on the path for this server-to-server call.
 *
 * Auth: HTTP Basic with agent-uc2 client_id:client_secret (client_secret_basic).
 */
export async function exchangeCodeForTokens(opts: {
  baseUrl: string;
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  code: string;
  codeVerifier: string;
}): Promise<TokenResponse> {
  const tokenUrl = `${opts.baseUrl}/oauth2/token`;
  const basic = Buffer.from(`${opts.clientId}:${opts.clientSecret}`).toString('base64');

  const res = await fetch(tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
      Authorization: `Basic ${basic}`
    },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code: opts.code,
      redirect_uri: opts.redirectUri,
      code_verifier: opts.codeVerifier
    })
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`IVIA token exchange failed [${res.status}]: ${body}`);
  }
  return (await res.json()) as TokenResponse;
}

