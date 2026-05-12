/**
 * /login — Server-side redirect to IVIA Authorization Code + PKCE endpoint.
 *
 * Builds the IVIA /authorize URL with:
 *   - response_type=code
 *   - code_challenge_method=S256 (PKCE)
 *   - code_challenge derived from a random code_verifier
 *   - state parameter for CSRF protection
 *
 * Stores code_verifier + state in a short-lived httpOnly cookie for
 * verification in the /callback handler.
 */

import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import crypto from 'crypto';
import type { PageServerLoad } from './$types';

function base64url(buf: Buffer): string {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

export const load: PageServerLoad = async ({ cookies, locals }) => {
  // Already authenticated — go to dashboard
  if (locals.accessToken) {
    throw redirect(302, '/dashboard');
  }

  const issuer = env.IVIA_ISSUER ?? '';
  const clientId = env.IVIA_CLIENT_ID ?? 'agent-uc2';
  const redirectUri = env.REDIRECT_URI ?? '';

  if (!issuer || !redirectUri) {
    throw new Error('IVIA_ISSUER and REDIRECT_URI environment variables must be set');
  }

  // Generate PKCE code_verifier (RFC 7636 §4.1: 43-128 chars of base64url)
  const codeVerifier = base64url(crypto.randomBytes(32));

  // code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))
  const codeChallenge = base64url(crypto.createHash('sha256').update(codeVerifier).digest());

  // State for CSRF protection
  const state = base64url(crypto.randomBytes(16));

  // Store verifier + state in httpOnly cookie (30min TTL)
  const pkcePayload = JSON.stringify({ codeVerifier, state });
  cookies.set('pkce', pkcePayload, {
    path: '/',
    httpOnly: true,
    secure: false, // HTTP-only ALB — lab environment only
    sameSite: 'lax',
    maxAge: 60 * 30,
  });

  // Build IVIA /authorize URL
  const authUrl = new URL(`${issuer}/oauth2/authorize`);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('client_id', clientId);
  authUrl.searchParams.set('redirect_uri', redirectUri);
  authUrl.searchParams.set('scope', 'openid profile email');
  authUrl.searchParams.set('code_challenge_method', 'S256');
  authUrl.searchParams.set('code_challenge', codeChallenge);
  authUrl.searchParams.set('state', state);

  throw redirect(302, authUrl.toString());
};
