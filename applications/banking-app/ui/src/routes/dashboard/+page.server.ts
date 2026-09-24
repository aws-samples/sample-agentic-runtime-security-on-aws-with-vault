/**
 * Dashboard server load — pass tokens to the page component.
 *
 * The access_token is forwarded from layout locals.
 * The id_token is read directly from the cookie for display-only decoding
 * (extracting user name/email for the welcome message).
 *
 * Neither token is stored in SvelteKit page state that persists across navigations.
 */

import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, cookies }) => {
  if (!locals.accessToken) {
    throw redirect(302, '/');
  }

  return {
    accessToken: locals.accessToken,
    idToken: cookies.get('id_token') ?? null,
  };
};
