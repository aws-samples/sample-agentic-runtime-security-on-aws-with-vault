/**
 * Dashboard server load — pass the access token to the page component.
 *
 * The access_token is forwarded from layout locals. The persona name shown in
 * the chat header comes from the root layout's display-only id_token decode, so
 * the id_token itself is not sent to the page.
 *
 * The token is not stored in SvelteKit page state that persists across navigations.
 */

import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
  if (!locals.accessToken) {
    throw redirect(302, '/');
  }

  return {
    accessToken: locals.accessToken,
  };
};
