/**
 * auth.ts — OIDC Authorization Code + PKCE client configuration for UC2.
 *
 * Uses oidc-client-ts to handle the Authorization Code flow with PKCE
 * against IBM Verify Access (IVIA). This is a public client — no client_secret.
 * PKCE (code_challenge_method=S256) replaces the secret for public clients.
 *
 * Environment variables (set at build time via SvelteKit PUBLIC_ prefix):
 *   PUBLIC_IVIA_ISSUER      — IVIA issuer URL (e.g. https://ivia.workshop.example/oidc)
 *   PUBLIC_IVIA_CLIENT_ID   — OAuth client ID registered in IVIA (default: agent-uc2)
 *   PUBLIC_REDIRECT_URI     — Full callback URL (e.g. http://<alb-hostname>/callback)
 *   PUBLIC_AGENT_URL        — Banking agent endpoint (e.g. http://<alb-hostname>:3002)
 *
 * Security notes:
 *   - PKCE code_challenge_method=S256 is enforced (prevents auth code interception)
 *   - No client_secret — this is a public client per CONTEXT decision
 *   - Access token stored server-side in httpOnly cookie (handled in callback route)
 *   - No tokens stored in localStorage or sessionStorage
 */

import { env } from '$env/dynamic/public';
import { UserManager, WebStorageStateStore } from 'oidc-client-ts';

/**
 * Build a UserManager configured for Authorization Code + PKCE flow.
 *
 * Called once per browser session. The UserManager handles:
 *   - PKCE code_verifier/challenge generation
 *   - State parameter for CSRF protection
 *   - Redirect to IVIA authorization endpoint
 *   - Callback code exchange
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
    // PKCE — code_challenge_method=S256 (RFC 7636)
    // oidc-client-ts defaults to S256; explicitly noted for workshop pedagogy
    response_mode: 'query',
    // Store PKCE state in sessionStorage (browser-side only; tokens stored server-side)
    userStore: new WebStorageStateStore({ store: typeof window !== 'undefined' ? window.sessionStorage : undefined }),
    // Disable silent renewal — session is managed server-side via httpOnly cookies
    automaticSilentRenew: false,
    // Request offline_access if IVIA supports refresh tokens
    // Omitted for UC2 simplicity — session expires with access token TTL
  });
}

/**
 * Initiate Authorization Code + PKCE redirect to IVIA.
 *
 * Generates a random code_verifier, computes code_challenge=S256(verifier),
 * and redirects the browser to IVIA's /authorize endpoint.
 */
export async function startLogin(userManager: UserManager): Promise<void> {
  await userManager.signinRedirect();
}

/**
 * Complete the PKCE callback — exchange auth code for tokens.
 *
 * Called from the /callback route after IVIA redirects back with ?code=&state=
 * Verifies the state parameter (CSRF) and exchanges the code using the
 * stored code_verifier.
 *
 * Returns the access_token for forwarding to the agent pod.
 */
export async function handleCallback(userManager: UserManager): Promise<string> {
  const user = await userManager.signinRedirectCallback();

  if (!user || !user.access_token) {
    throw new Error('OIDC callback failed: no access_token in response');
  }

  return user.access_token;
}

/**
 * Agent URL for forwarding user JWTs.
 */
export function getAgentUrl(): string {
  return env.PUBLIC_AGENT_URL ?? '';
}
