/**
 * /callback — OAuth Authorization Code exchange handler.
 *
 * IVIA redirects here after user authenticates with ?code=&state=
 * This handler:
 *   1. Verifies state matches the stored CSRF token.
 *   2. Retrieves code_verifier from the pkce cookie.
 *   3. POSTs to IVIA /token endpoint with code + code_verifier (PKCE).
 *   4. Stores access_token + id_token in httpOnly session cookies.
 *   5. Redirects to /dashboard.
 *
 * Security: All token handling is server-side. Tokens never touch the browser DOM.
 */

import { redirect, error } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { PageServerLoad } from './$types';

interface TokenResponse {
  access_token: string;
  id_token?: string;
  refresh_token?: string;
  expires_in?: number;
  token_type?: string;
}

export const load: PageServerLoad = async ({ url, cookies }) => {
  const code = url.searchParams.get('code');
  const returnedState = url.searchParams.get('state');
  const errorParam = url.searchParams.get('error');

  // Handle IVIA error responses
  if (errorParam) {
    const desc = url.searchParams.get('error_description') ?? errorParam;
    throw error(400, `OAuth error: ${desc}`);
  }

  if (!code) {
    throw error(400, 'Missing authorization code in callback');
  }

  // Retrieve PKCE state from cookie
  const pkceRaw = cookies.get('pkce');
  if (!pkceRaw) {
    throw error(400, 'PKCE cookie missing — session may have expired');
  }

  let pkce: { codeVerifier: string; state: string };
  try {
    pkce = JSON.parse(pkceRaw) as { codeVerifier: string; state: string };
  } catch {
    throw error(400, 'Malformed PKCE cookie');
  }

  // Validate state (CSRF protection)
  if (!returnedState || returnedState !== pkce.state) {
    throw error(400, 'State mismatch — possible CSRF attack');
  }

  // Clear the PKCE cookie (one-time use)
  cookies.delete('pkce', { path: '/' });

  const issuer = env.IVIA_ISSUER ?? '';
  const clientId = env.IVIA_CLIENT_ID ?? 'agent-uc2';
  const redirectUri = env.REDIRECT_URI ?? '';

  if (!issuer || !redirectUri) {
    throw error(500, 'IVIA_ISSUER and REDIRECT_URI must be configured');
  }

  // Exchange authorization code for tokens
  const tokenUrl = `${issuer}/oauth2/token`;
  const res = await fetch(tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: redirectUri,
      client_id: clientId,
      code_verifier: pkce.codeVerifier,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw error(502, `IVIA token exchange failed [${res.status}]: ${body}`);
  }

  const tokens = (await res.json()) as TokenResponse;

  if (!tokens.access_token) {
    throw error(502, 'IVIA token response missing access_token');
  }

  const maxAge = tokens.expires_in ?? 3600;

  // Store access_token in httpOnly cookie — forwarded to agent as Bearer token
  cookies.set('access_token', tokens.access_token, {
    path: '/',
    httpOnly: true,
    secure: false, // HTTP-only ALB — lab environment only
    sameSite: 'lax',
    maxAge,
  });

  // Store id_token for user display (name, email from IVIA claims)
  if (tokens.id_token) {
    cookies.set('id_token', tokens.id_token, {
      path: '/',
      httpOnly: true,
      secure: false,
      sameSite: 'lax',
      maxAge: 60 * 60 * 24,
    });
  }

  throw redirect(302, '/dashboard');
};
