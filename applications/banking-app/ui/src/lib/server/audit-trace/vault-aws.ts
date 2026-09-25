/**
 * vault-aws.ts — the UI server's short-lived, read-only AWS keys for the Audit Trace card.
 *
 * The banking UI has no AWS identity of its own and no AWS key anywhere in its
 * configuration. When it needs to query Athena it:
 *   1. logs in to Vault with its Kubernetes service-account token (uc2-ui-sa, Vault
 *      role VAULT_ROLE = banking-ui, auth/kubernetes/login);
 *   2. reads aws/sts/audit-reader with that Vault token — the only path its policy
 *      allows — and gets STS keys for the audit-reader IAM role, limited to Athena
 *      in work group `workshop` and the audit tables (infrastructure/main.tf);
 *   3. keeps those keys until five minutes before they expire (900 s), then does
 *      1-2 again. The Vault token is not kept: every refresh is a fresh login.
 *
 * Same pattern as the Use Case 3 agent's get_logs_credentials()
 * (applications/uc3-agent/app/vault_client.py).
 *
 * These are the UI server's own credentials, not a credential issued for a user's
 * turn: they are never returned to the browser, never put on an event stream and
 * never logged. Errors carry Vault's own error strings, which name no secret.
 */

import { readFile } from 'node:fs/promises';
import { env } from '$env/dynamic/private';

/** The Vault path the banking-ui policy can read (modules/vault_config). */
export const AUDIT_READER_STS_PATH = 'aws/sts/audit-reader';

/** Where Kubernetes mounts the pod's service-account token. */
const DEFAULT_SA_TOKEN_PATH = '/var/run/secrets/kubernetes.io/serviceaccount/token';

/**
 * Refresh this long before the keys expire, so no query starts on keys about to lapse.
 * Five minutes is the AWS SDK's own window: it asks for new keys once the held ones are
 * within 300 s of expiry (@smithy/core EXPIRATION_MS), so a shorter margin here would
 * only hand the SDK the same keys again.
 */
const REFRESH_MARGIN_MS = 300_000;

export interface AuditReaderCredentials {
	accessKeyId: string;
	secretAccessKey: string;
	sessionToken: string;
	expiration: Date;
}

export class VaultCredentialError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'VaultCredentialError';
	}
}

let cached: AuditReaderCredentials | null = null;
let inFlight: Promise<AuditReaderCredentials> | null = null;

async function vaultErrors(res: Response): Promise<string> {
	try {
		const body = (await res.json()) as { errors?: unknown };
		if (Array.isArray(body.errors) && body.errors.every((e) => typeof e === 'string')) {
			return body.errors.join('; ');
		}
	} catch {
		// not JSON
	}
	return `HTTP ${res.status}`;
}

/**
 * fetch() against Vault, with a network failure or timeout reported as a Vault error.
 * Without this the bare "fetch failed" reached the card as "The audit query failed",
 * naming no step — the one case an attendee most needs named (Vault down, or the pod's
 * egress to Vault on 8200 missing).
 */
async function vaultFetch(url: string, init: RequestInit, step: string): Promise<Response> {
	try {
		return await fetch(url, init);
	} catch (err) {
		const cause = (err as { cause?: { code?: unknown } })?.cause?.code;
		const reason = `${err instanceof Error ? err.message : String(err)}${typeof cause === 'string' ? ` (${cause})` : ''}`;
		throw new VaultCredentialError(`cannot reach Vault at ${env.VAULT_ADDR} for ${step}: ${reason}`);
	}
}

async function issue(): Promise<AuditReaderCredentials> {
	const vaultAddr = env.VAULT_ADDR;
	const role = env.VAULT_ROLE;
	if (!vaultAddr || !role) {
		throw new VaultCredentialError('VAULT_ADDR and VAULT_ROLE must be set for the Audit Trace endpoint');
	}
	const tokenPath = env.VAULT_K8S_TOKEN_PATH || DEFAULT_SA_TOKEN_PATH;

	let jwt: string;
	try {
		jwt = (await readFile(tokenPath, 'utf8')).trim();
	} catch {
		throw new VaultCredentialError(`cannot read the service-account token at ${tokenPath}`);
	}

	const login = await vaultFetch(
		`${vaultAddr}/v1/auth/kubernetes/login`,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ role, jwt }),
			signal: AbortSignal.timeout(10_000)
		},
		`the login as ${role}`
	);
	if (!login.ok) {
		throw new VaultCredentialError(`Vault login as ${role} failed: ${await vaultErrors(login)}`);
	}
	const loginBody = (await login.json()) as { auth?: { client_token?: unknown } };
	const vaultToken = loginBody.auth?.client_token;
	if (typeof vaultToken !== 'string' || vaultToken === '') {
		throw new VaultCredentialError(`Vault login as ${role} returned no token`);
	}

	const read = await vaultFetch(
		`${vaultAddr}/v1/${AUDIT_READER_STS_PATH}`,
		{
			headers: { 'X-Vault-Token': vaultToken },
			signal: AbortSignal.timeout(15_000)
		},
		`the read of ${AUDIT_READER_STS_PATH}`
	);
	if (!read.ok) {
		throw new VaultCredentialError(`Vault read of ${AUDIT_READER_STS_PATH} failed: ${await vaultErrors(read)}`);
	}
	const body = (await read.json()) as {
		lease_duration?: unknown;
		data?: { access_key?: unknown; secret_key?: unknown; security_token?: unknown };
	};
	const data = body.data ?? {};
	if (typeof data.access_key !== 'string' || typeof data.secret_key !== 'string' || typeof data.security_token !== 'string') {
		throw new VaultCredentialError(`Vault read of ${AUDIT_READER_STS_PATH} returned no STS keys`);
	}
	const leaseSeconds = typeof body.lease_duration === 'number' && body.lease_duration > 0 ? body.lease_duration : 900;
	return {
		accessKeyId: data.access_key,
		secretAccessKey: data.secret_key,
		sessionToken: data.security_token,
		expiration: new Date(Date.now() + leaseSeconds * 1000)
	};
}

/**
 * Current audit-reader keys, issuing new ones when none are held or they are within
 * five minutes of expiry. Concurrent callers share one issue. Usable directly as an
 * AWS SDK credential provider.
 */
export async function auditReaderCredentials(): Promise<AuditReaderCredentials> {
	if (cached && cached.expiration.getTime() - Date.now() > REFRESH_MARGIN_MS) return cached;
	if (!inFlight) {
		inFlight = issue()
			.then((credentials) => {
				cached = credentials;
				return credentials;
			})
			.finally(() => {
				inFlight = null;
			});
	}
	return inFlight;
}

/** Drop the held keys, e.g. after AWS rejected them, so the next call issues fresh ones. */
export function forgetAuditReaderCredentials(): void {
	cached = null;
}
