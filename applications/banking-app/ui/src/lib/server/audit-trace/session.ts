/**
 * session.ts — who is signed in, proven rather than read.
 *
 * The Audit Trace endpoint must know which user is asking, because it returns only
 * that user's audit rows. The id_token cookie being present proves nothing: this
 * module verifies it the way the Use Case 3 agent does before it acts for anyone
 * (applications/uc3-agent/app/auth.py `verify_id_token`):
 *   - signature: RS256 only, against IVIA's JWKS, fetched from the in-cluster
 *     iviaop service (IVIA_BASE_URL) over the CA mounted as NODE_EXTRA_CA_CERTS;
 *   - issuer: the one IVIA's discovery document names;
 *   - audience: this app's own OAuth client (IVIA_CLIENT_ID, agent-uc2), the client
 *     whose code flow minted the token;
 *   - expiry: exp must be in the future; sub, iss, aud and exp are required.
 * Anything else — no cookie, a forged or expired token, another client's token — is
 * no session. Only the verified `sub` leaves this module.
 */

import { env } from '$env/dynamic/private';
import { createRemoteJWKSet, errors, jwtVerify } from 'jose';

export type SessionFailure = 'no_session' | 'expired' | 'invalid' | 'unavailable' | 'misconfigured';

export class SessionError extends Error {
	constructor(readonly failure: SessionFailure) {
		super(failure);
		this.name = 'SessionError';
	}
}

export interface VerifiedSession {
	/** The signed-in user's `sub`, from a verified id_token. */
	sub: string;
}

interface Verifier {
	issuer: string;
	audience: string;
	jwks: ReturnType<typeof createRemoteJWKSet>;
}

let verifier: Promise<Verifier> | null = null;

async function loadVerifier(): Promise<Verifier> {
	const baseUrl = env.IVIA_BASE_URL;
	const audience = env.IVIA_CLIENT_ID;
	if (!baseUrl || !audience) throw new SessionError('misconfigured');

	const res = await fetch(`${baseUrl}/oauth2/.well-known/openid-configuration`, {
		headers: { Accept: 'application/json' },
		signal: AbortSignal.timeout(10_000)
	});
	if (!res.ok) throw new SessionError('unavailable');
	const discovery = (await res.json()) as { issuer?: unknown };
	if (typeof discovery.issuer !== 'string' || discovery.issuer === '') throw new SessionError('unavailable');

	// Split-horizon, as in auth.py: discovery names the PUBLIC issuer (the token's
	// `iss`), but the keys are fetched from the internal service we already trust.
	return {
		issuer: discovery.issuer,
		audience,
		jwks: createRemoteJWKSet(new URL(`${baseUrl}/oauth2/jwks`))
	};
}

async function getVerifier(): Promise<Verifier> {
	if (!verifier) {
		verifier = loadVerifier();
		// A failed discovery is retried on the next request, not cached.
		verifier.catch(() => {
			verifier = null;
		});
	}
	return verifier;
}

/**
 * The verified session of this request, or a SessionError saying why there is none.
 * The token's bytes are never logged or returned.
 */
export async function verifySession(idToken: string | undefined): Promise<VerifiedSession> {
	if (!idToken) throw new SessionError('no_session');
	const { issuer, audience, jwks } = await getVerifier();
	try {
		const { payload } = await jwtVerify(idToken, jwks, {
			algorithms: ['RS256'],
			issuer,
			audience,
			requiredClaims: ['sub', 'iss', 'aud', 'exp']
		});
		if (typeof payload.sub !== 'string' || payload.sub === '') throw new SessionError('invalid');
		return { sub: payload.sub };
	} catch (err) {
		if (err instanceof SessionError) throw err;
		if (err instanceof errors.JWTExpired) throw new SessionError('expired');
		// The key set could not be fetched (network failure, timeout, a non-200 from
		// iviaop): IVIA is unreachable, which says nothing about the token.
		if (!(err instanceof errors.JOSEError) || err instanceof errors.JWKSTimeout || err.code === 'ERR_JOSE_GENERIC') {
			throw new SessionError('unavailable');
		}
		throw new SessionError('invalid');
	}
}
