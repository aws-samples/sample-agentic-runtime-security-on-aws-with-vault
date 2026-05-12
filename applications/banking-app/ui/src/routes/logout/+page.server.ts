/**
 * /logout — Clear session and redirect to IVIA end_session_endpoint.
 *
 * Clears all session cookies then redirects to IVIA's logout URL
 * so the SSO session at the IdP is also terminated (not just the
 * browser-side cookie). This ensures the Vault credential lease
 * associated with the session is also revoked (Phase 6 demo).
 *
 * After IVIA logout, the user is redirected back to the app landing page.
 */

import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ cookies }) => {
  // Read id_token before clearing (needed for IVIA end_session hint)
  const idToken = cookies.get('id_token');

  // Clear all session cookies
  cookies.delete('access_token', { path: '/' });
  cookies.delete('id_token', { path: '/' });
  cookies.delete('pkce', { path: '/' });

  const issuer = env.IVIA_ISSUER ?? '';
  const postLogoutUri = env.POST_LOGOUT_REDIRECT_URI ?? env.REDIRECT_URI?.replace('/callback', '') ?? '/';

  // Build IVIA end_session_endpoint URL
  if (issuer) {
    const logoutUrl = new URL(`${issuer}/oauth2/logout`);
    logoutUrl.searchParams.set('post_logout_redirect_uri', postLogoutUri);
    if (idToken) {
      // id_token_hint lets IVIA skip the confirmation prompt
      logoutUrl.searchParams.set('id_token_hint', idToken);
    }
    throw redirect(302, logoutUrl.toString());
  }

  // Fallback: no IVIA issuer configured — just go home
  throw redirect(302, '/');
};
