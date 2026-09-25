/**
 * session-lifetime.ts — when a banking UI sign-in stops counting, decided once.
 *
 * The answers to "has this sign-in expired?" and "which cookies hold it, with which
 * attributes?" live here, so no two parts of the UI can answer differently:
 *   - lib/server/audit-trace/session.ts: has the Audit Trace caller's sign-in expired?
 *   - routes/callback/+page.server.ts: how long each session cookie lives.
 *   - routes/logout/+server.ts: which cookies to clear, and with which attributes.
 *
 * The rule is jose's (the library that verifies the Audit Trace's id_token): a token
 * is expired once `exp <= now - leeway`, with `now` in whole seconds rounded down.
 * The leeway is 0, jose's default and what the Audit Trace has always used.
 *
 * Nothing here verifies a signature. readExp only decodes the payload, so its answer
 * is trusted for one thing: deciding that a session is OVER. Deciding who someone is
 * stays with the code that verifies the token.
 */

import { decodeJwt } from 'jose';

/** Clock leeway on `exp`, in seconds. Passed to jose as `clockTolerance`, too. */
export const CLOCK_TOLERANCE_SECONDS = 0;

/** The cookies that hold a banking UI sign-in. */
export const SESSION_COOKIES = ['access_token', 'id_token', 'refresh_token'] as const;

/**
 * The attributes every session cookie is set and cleared with. A browser only
 * replaces or deletes a cookie whose path (and domain) match, so setting and
 * clearing must use the same ones.
 */
export const SESSION_COOKIE_OPTIONS = { path: '/', secure: true, httpOnly: true, sameSite: 'lax' } as const;

/** Now, in whole seconds since the epoch, rounded down the way jose rounds it. */
export function nowSeconds(): number {
	return Math.floor(Date.now() / 1000);
}

/** The token's `exp` claim, decoded WITHOUT verification, or null if it has no readable one. */
export function readExp(token: string | undefined): number | null {
	if (!token) return null;
	try {
		const { exp } = decodeJwt(token);
		return typeof exp === 'number' && Number.isFinite(exp) ? exp : null;
	} catch {
		return null;
	}
}

/** Whether a token with this `exp` has expired. */
export function isExpired(exp: number, now: number = nowSeconds()): boolean {
	return exp <= now - CLOCK_TOLERANCE_SECONDS;
}

/** Whole seconds until `exp`, never below 0: the Max-Age of the cookie holding the token. */
export function secondsLeft(exp: number, now: number = nowSeconds()): number {
	return Math.max(0, exp - now);
}
