import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { RequestHandler } from './$types';

/**
 * /logout — terminate BOTH sessions, not just the banking-ui cookie.
 *
 * IVIA runs as a WebSEAL point-of-contact in front of the OIDC Provider
 * (provider.yml authentication.endpoint = <wrp>/oauth2/auth). WebSEAL is the
 * front-line authenticator: it holds the real session (created on the LDAP
 * bind) and re-injects the user as `iv-jwt` on every /oauth2/auth. Deleting
 * only the banking-ui cookies leaves that WebSEAL session alive, so the next
 * visit silently re-authenticates as the same user with no credential prompt
 * — the "logout doesn't log out" symptom.
 *
 * The WebSEAL session cookie is scoped to the WRP host (a different origin
 * than this banking-ui host), so this server CANNOT delete it directly. We
 * must bounce the browser to WebSEAL's built-in /pkmslogout endpoint, which
 * destroys the WebSEAL session at its own origin. After that, the next
 * /oauth2/authorize → /oauth2/auth finds no WebSEAL session and forces a
 * fresh LDAP login.
 *
 * IVIA_ISSUER is the public WRP issuer ending in /isvaop
 * (e.g. https://wrp.<id>.<ip>.nip.io/isvaop); its origin is the WRP host that
 * serves /pkmslogout.
 */
export const GET: RequestHandler = async ({ cookies }) => {
	const cookieOpts = { path: '/', secure: true, httpOnly: true, sameSite: 'lax' as const };
	cookies.delete('access_token', cookieOpts);
	cookies.delete('id_token', cookieOpts);
	cookies.delete('refresh_token', cookieOpts);

	// Bounce the browser to WebSEAL /pkmslogout to kill the front-line session.
	// Fall back to /ask if the issuer is unset/malformed so logout never 500s.
	const issuer = env.IVIA_ISSUER ?? '';
	let wrpLogoutUrl = '/ask';
	if (issuer) {
		try {
			wrpLogoutUrl = `${new URL(issuer).origin}/pkmslogout`;
		} catch {
			wrpLogoutUrl = '/ask';
		}
	}

	throw redirect(302, wrpLogoutUrl);
};
