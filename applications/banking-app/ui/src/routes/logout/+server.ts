import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ cookies }) => {
	const idToken = cookies.get('id_token');

	const cookieOpts = { path: '/', secure: false, httpOnly: true, sameSite: 'lax' as const };
	cookies.delete('access_token', cookieOpts);
	cookies.delete('id_token', cookieOpts);
	cookies.delete('refresh_token', cookieOpts);

	const issuer = env.IVIA_ISSUER ?? '';
	const postLogoutUri =
		env.POST_LOGOUT_REDIRECT_URI ?? env.REDIRECT_URI?.replace('/callback', '') ?? '/';

	throw redirect(302, '/');
};
