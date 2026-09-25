/**
 * Root landing — server-side OAuth Authorization Code + PKCE initiator.
 *
 * Behavior:
 *   - If the request is signed in (locals.accessToken, which hooks.server.ts
 *     sets only while the id_token has not expired) → /dashboard.
 *   - Otherwise → generate PKCE state, store it in a short-lived httpOnly
 *     cookie, and 302 the browser to IVIA /oauth2/authorize. The browser
 *     never sees a banking-ui login form; WebSEAL (the IVIA WRP) serves
 *     the login page in front of /isvaop/oauth2/authorize.
 */

import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { PageServerLoad } from './$types';
import { buildAuthorizeUrl, generatePkce } from '$lib/auth';

export const load: PageServerLoad = async ({ locals, cookies }) => {
  if (locals.accessToken) {
    throw redirect(302, '/dashboard');
  }

  // No fallback for any of these: the client ID names which OAuth client the sign-in
  // is for, and a guessed one would sign people in against the wrong client silently.
  const issuer = env.IVIA_ISSUER ?? '';
  const clientId = env.IVIA_CLIENT_ID ?? '';
  const redirectUri = env.REDIRECT_URI ?? '';

  if (!issuer || !clientId || !redirectUri) {
    throw new Error('IVIA_ISSUER, IVIA_CLIENT_ID and REDIRECT_URI must be set');
  }

  const pkce = generatePkce();
  cookies.set(
    'pkce',
    JSON.stringify({ codeVerifier: pkce.codeVerifier, state: pkce.state }),
    {
      path: '/',
      httpOnly: true,
      secure: true,
      sameSite: 'lax',
      maxAge: 600
    }
  );

  throw redirect(
    302,
    buildAuthorizeUrl({
      issuer,
      clientId,
      redirectUri,
      codeChallenge: pkce.codeChallenge,
      state: pkce.state
    })
  );
};
