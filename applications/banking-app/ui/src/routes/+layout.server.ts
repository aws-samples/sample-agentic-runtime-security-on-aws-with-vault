/**
 * +layout.server.ts — Root layout server load.
 *
 * Checks for a valid session on every page load. If no access_token cookie
 * is present, redirects to the IVIA login (Authorization Code + PKCE flow
 * initiated from +page.svelte / login route).
 *
 * The access_token is passed to page components so the dashboard can
 * forward it to the agent pod via Authorization header.
 */

import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';

// Pages that do NOT require a banking-ui session cookie. The root path
// is public because the load() function on / handles the redirect to
// IVIA when no session exists.
const PUBLIC_PATHS = ['/', '/callback', '/logout'];

export const load: LayoutServerLoad = async ({ locals, url }) => {
  const isPublic = PUBLIC_PATHS.some((p) => url.pathname === p || url.pathname.startsWith(p + '/'));

  if (!isPublic && !locals.accessToken) {
    throw redirect(302, '/');
  }

  return {
    accessToken: locals.accessToken ?? null,
  };
};
