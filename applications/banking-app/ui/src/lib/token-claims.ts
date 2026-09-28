/**
 * token-claims.ts — the decoded claims of the two sign-in tokens, as the persona menu shows them.
 *
 * The UI server decodes the id_token and access_token cookies (lib/server/sign-in-claims.ts)
 * and sends the page only these claims, never the token strings. This module is the shape of
 * that data and the one rule for turning a claim into the text in its row.
 *
 * Values are shown as the token carries them, the way the reference demo shows them:
 *   - strings as they are; an empty string as "" so the row is visibly empty, not blank;
 *   - numbers (exp, iat, auth_time ...) as the epoch seconds the token holds, not as dates;
 *   - an `aud` holding a single audience as that audience;
 *   - objects (act) and any other array as compact JSON.
 * Rows are in claim-name order.
 */

/** One token's claims, or the fact that they could not be read. */
export type TokenClaims = { readable: true; claims: Record<string, unknown> } | { readable: false };

/** The two tokens IBM Verify issued at sign-in. */
export interface SignInClaims {
	idToken: TokenClaims;
	accessToken: TokenClaims;
}

export interface ClaimRow {
	name: string;
	value: string;
}

/** The text a claim's row shows. */
export function formatClaim(name: string, value: unknown): string {
	if (typeof value === 'string') return value === '' ? '""' : value;
	if (typeof value === 'number' || typeof value === 'boolean') return String(value);
	if (value === null) return 'null';
	if (Array.isArray(value)) {
		if (name === 'aud' && value.length === 1) return formatClaim(name, value[0]);
		return JSON.stringify(value);
	}
	if (typeof value === 'object') return JSON.stringify(value);
	return String(value);
}

/** Every claim as a row, in claim-name order. */
export function claimRows(claims: Record<string, unknown>): ClaimRow[] {
	return Object.keys(claims)
		.sort()
		.map((name) => ({ name, value: formatClaim(name, claims[name]) }));
}
