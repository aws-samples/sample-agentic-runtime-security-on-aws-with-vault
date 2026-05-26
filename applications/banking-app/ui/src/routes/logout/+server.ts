import { redirect } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ cookies }) => {
	const cookieOpts = { path: '/', secure: false, httpOnly: true, sameSite: 'lax' as const };
	cookies.delete('access_token', cookieOpts);
	cookies.delete('id_token', cookieOpts);
	cookies.delete('refresh_token', cookieOpts);

	// After signing out, land on the public, non-authenticated Use Case 1 chat
	// page (/ask) rather than '/', which would bounce back into the IVIA login.
	throw redirect(302, '/ask');
};
