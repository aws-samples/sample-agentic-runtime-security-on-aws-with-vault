/**
 * /callback — OAuth Authorization Code exchange.
 *
 * IVIA redirects here after the user authenticates at WebSEAL with
 * ?code=&state=. This handler:
 *   1. Validates state matches the stored CSRF token.
 *   2. Retrieves code_verifier from the pkce cookie.
 *   3. POSTs to IVIA /oauth2/token (in-cluster DNS — bypasses WRP ALB)
 *      with HTTP Basic client_id:client_secret auth.
 *   4. Stores access_token + id_token in httpOnly session cookies.
 *   5. Redirects to /dashboard.
 *
 * Security: all token handling is server-side. Tokens never reach the browser DOM.
 * The token exchange is server-to-server over the in-cluster service URL
 * (IVIA_BASE_URL), so the WRP ALB is not on the path here.
 */

import { redirect, error } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { PageServerLoad } from './$types';
import { exchangeCodeForTokens } from '$lib/auth';

export const load: PageServerLoad = async ({ url, cookies }) => {
  const code = url.searchParams.get('code');
  const returnedState = url.searchParams.get('state');
  const errorParam = url.searchParams.get('error');

  if (errorParam) {
    const desc = url.searchParams.get('error_description') ?? errorParam;
    throw error(400, `OAuth error: ${desc}`);
  }
  if (!code) {
    throw error(400, 'Missing authorization code in callback');
  }

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

  if (!returnedState || returnedState !== pkce.state) {
    throw error(400, 'State mismatch — possible CSRF attack');
  }

  cookies.delete('pkce', { path: '/' });

  const baseUrl = env.IVIA_BASE_URL ?? '';
  const clientId = env.IVIA_CLIENT_ID ?? 'agent-uc2';
  const clientSecret = env.IVIA_CLIENT_SECRET ?? '';
  const redirectUri = env.REDIRECT_URI ?? '';

  if (!baseUrl || !clientSecret || !redirectUri) {
    throw error(500, 'IVIA_BASE_URL, IVIA_CLIENT_SECRET, and REDIRECT_URI must be configured');
  }

  let tokens;
  try {
    tokens = await exchangeCodeForTokens({
      baseUrl,
      clientId,
      clientSecret,
      redirectUri,
      code,
      codeVerifier: pkce.codeVerifier
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw error(502, msg);
  }

  if (!tokens.access_token) {
    throw error(502, 'IVIA token response missing access_token');
  }

  const maxAge = tokens.expires_in ?? 3600;

  cookies.set('access_token', tokens.access_token, {
    path: '/',
    httpOnly: true,
    secure: true,
    sameSite: 'lax',
    maxAge
  });

  if (tokens.id_token) {
    cookies.set('id_token', tokens.id_token, {
      path: '/',
      httpOnly: true,
      secure: true,
      sameSite: 'lax',
      maxAge: 60 * 60 * 24
    });
  }

  if (tokens.refresh_token) {
    cookies.set('refresh_token', tokens.refresh_token, {
      path: '/',
      httpOnly: true,
      secure: true,
      sameSite: 'lax',
      maxAge: 60 * 60 * 24 * 30
    });
  }

  throw redirect(302, '/dashboard');
};
