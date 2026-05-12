/**
 * hooks.server.ts — SvelteKit server hooks for the banking UI.
 *
 * Validates session on every server-side request by checking the
 * access_token cookie. If missing, downstream +layout.server.ts and
 * route load functions handle the redirect to IVIA login.
 */

import type { Handle } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  const accessToken = event.cookies.get('access_token');
  event.locals.accessToken = accessToken ?? null;

  return resolve(event);
};
