/**
 * /callback — OAuth Authorization Code exchange.
 *
 * IVIA redirects here after the user authenticates at WebSEAL with
 * ?code=&state=. This handler:
 *   1. Validates state matches the stored CSRF token.
 *   2. Retrieves code_verifier from the pkce cookie.
 *   3. POSTs to IVIA /oauth2/token (in-cluster DNS — bypasses WRP ALB)
 *      with HTTP Basic client_id:client_secret auth.
 *   4. Stores access_token + id_token (and refresh_token, when IVIA returns
 *      one) in httpOnly session cookies. The access_token and id_token cookies
 *      each live exactly as long as their own token: Max-Age is the seconds left
 *      until the token's `exp` (never below 0), not expires_in and not a fixed
 *      time. A response without an id_token, or a token without a readable
 *      `exp`, is refused rather than given a made-up lifetime: the id_token is
 *      what says who signed in and when that sign-in ends.
 *   5. Redirects to /dashboard.
 *
 * Security: the tokens are held in httpOnly cookies, so no page script can
 * read them from the cookie jar. They still reach the browser in two ways:
 *   - page data: the root layout load (routes/+layout.server.ts) gives every
 *     signed-in page the access token, and the dashboard load
 *     (routes/dashboard/+page.server.ts) gives it the id token as well;
 *   - the chat stream: agent:credential events show, in full, every token and
 *     credential an agent issues or presents during a turn
 *     (lib/agent-events.ts, passed by lib/server/activity-filter.ts).
 * The token exchange is server-to-server over the in-cluster service URL
 * (IVIA_BASE_URL), so the WRP ALB is not on the path here.
 */

import { redirect, error } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { PageServerLoad } from './$types';
import { exchangeCodeForTokens } from '$lib/auth';
import { SESSION_COOKIE_OPTIONS, nowSeconds, readExp, secondsLeft } from '$lib/server/session-lifetime';

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

  // No fallback for the client ID: it names the OAuth client the code was issued to.
  const baseUrl = env.IVIA_BASE_URL ?? '';
  const clientId = env.IVIA_CLIENT_ID ?? '';
  const clientSecret = env.IVIA_CLIENT_SECRET ?? '';
  const redirectUri = env.REDIRECT_URI ?? '';

  if (!baseUrl || !clientId || !clientSecret || !redirectUri) {
    throw error(500, 'IVIA_BASE_URL, IVIA_CLIENT_ID, IVIA_CLIENT_SECRET, and REDIRECT_URI must be configured');
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
  if (!tokens.id_token) {
    throw error(502, 'IVIA token response missing id_token');
  }

  // Read, not verified: the cookie's lifetime is the only thing taken from it.
  const accessExp = readExp(tokens.access_token);
  const idExp = readExp(tokens.id_token);
  if (accessExp === null) {
    throw error(502, 'IVIA access_token has no readable exp claim');
  }
  if (idExp === null) {
    throw error(502, 'IVIA id_token has no readable exp claim');
  }

  const now = nowSeconds();

  cookies.set('access_token', tokens.access_token, {
    ...SESSION_COOKIE_OPTIONS,
    maxAge: secondsLeft(accessExp, now)
  });

  cookies.set('id_token', tokens.id_token, {
    ...SESSION_COOKIE_OPTIONS,
    maxAge: secondsLeft(idExp, now)
  });

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
