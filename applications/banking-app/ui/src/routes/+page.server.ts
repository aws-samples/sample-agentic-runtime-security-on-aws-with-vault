/**
 * +page.server.ts — Root landing page server load.
 *
 * Reads the `error` query parameter set by the /login action on failure
 * and passes a human-readable message to the login form.
 *
 * If the user already has a valid session (access_token cookie), redirect
 * them to /dashboard so they don't see the login form again.
 */

import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ url, locals }) => {
  // Already authenticated — skip the login form
  if (locals.accessToken) {
    throw redirect(302, '/dashboard');
  }

  const errorParam = url.searchParams.get('error');
  let errorMessage: string | null = null;

  if (errorParam === 'login_failed') {
    errorMessage = 'Login failed. Check your username and password and try again.';
  } else if (errorParam) {
    errorMessage = 'An error occurred. Please try again.';
  }

  return { error: errorMessage };
};
