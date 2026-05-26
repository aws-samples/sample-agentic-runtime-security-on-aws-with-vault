/**
 * +layout.server.ts — Root layout server load.
 *
 * Checks for a valid session on every page load. If no access_token cookie
 * is present, redirects to the IVIA login (Authorization Code + PKCE flow
 * initiated from +page.svelte / login route).
 *
 * The access_token is passed to page components so the dashboard can
 * forward it to the agent pod via Authorization header.
 *
 * Decodes displayName and sub from the id_token cookie for DISPLAY-ONLY use
 * in the header user menu. This does NOT affect auth gating (hooks.server.ts
 * controls that via locals.accessToken).
 */

import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';

// Pages that do NOT require a banking-ui session cookie. The root path
// is public because the load() function on / handles the redirect to
// IVIA when no session exists.
const PUBLIC_PATHS = ['/', '/callback', '/logout'];

export const load: LayoutServerLoad = async ({ locals, cookies, url }) => {
  const isPublic = PUBLIC_PATHS.some((p) => url.pathname === p || url.pathname.startsWith(p + '/'));

  if (!isPublic && !locals.accessToken) {
    throw redirect(302, '/');
  }

  // Decode display name and sub from the id_token cookie — display only.
  // Auth gating remains solely in hooks.server.ts (locals.accessToken).
  let displayName = '';
  let sub = '';
  try {
    const idToken = cookies.get('id_token');
    if (idToken) {
      const payload = JSON.parse(Buffer.from(idToken.split('.')[1], 'base64').toString());
      displayName = payload.name ?? payload.preferred_username ?? payload.sub ?? '';
      sub = payload.sub ?? '';
    }
  } catch {
    // Not logged in or token malformed — leave displayName/sub as empty strings.
  }

  return {
    accessToken: locals.accessToken ?? null,
    displayName,
    sub,
  };
};
