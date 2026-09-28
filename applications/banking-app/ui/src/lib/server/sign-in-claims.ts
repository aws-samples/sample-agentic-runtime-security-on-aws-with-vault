/**
 * sign-in-claims.ts — the claims of the two tokens IBM Verify issued at sign-in, for the
 * persona menu.
 *
 * The id_token and access_token cookies are httpOnly: the browser never reads them. The root
 * layout decodes them here, from the request's own cookies, and sends the page only their
 * claims. The token strings never leave the server for this.
 *
 * Decoding is NOT verification: no signature is checked. What this returns is for showing
 * the room what the tokens say, never for deciding who someone is; hooks.server.ts decides
 * whether the request is signed in, and the code that acts on a token verifies it first.
 *
 * A token that cannot be decoded (missing, not a JWT, a payload that is not a JSON object),
 * or whose claims hold a key named "__proto__" that the page data cannot carry, comes back as
 * { readable: false } and the menu says its claims could not be read. Nothing here throws, and
 * no claim value is logged.
 */

import type { Cookies } from '@sveltejs/kit';
import { decodeJwt } from 'jose';
import type { SignInClaims, TokenClaims } from '$lib/token-claims';

function decode(token: string | undefined): TokenClaims {
	if (!token) return { readable: false };
	try {
		const claims = { ...decodeJwt(token) };
		// SvelteKit cannot send the page an object with a "__proto__" key, at any depth: the whole
		// page would fail with a 500. Such a token reads as unreadable instead.
		if (JSON.stringify(claims).includes('"__proto__":')) return { readable: false };
		return { readable: true, claims };
	} catch {
		return { readable: false };
	}
}

/** The decoded claims of this request's id_token and access_token cookies. */
export function readSignInClaims(cookies: Cookies): SignInClaims {
	return {
		idToken: decode(cookies.get('id_token')),
		accessToken: decode(cookies.get('access_token'))
	};
}
