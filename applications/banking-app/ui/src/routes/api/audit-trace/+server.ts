/**
 * GET /api/audit-trace?requestId=<uuid> — the Audit Trace card's Athena rows.
 *
 * Issue #68 · Audit Trace card: each answer links to the audit records every system
 * wrote for it. Under a Use Case 3 refund the card asks this route for the
 * audit_correlation rows of the turn's request ID.
 *
 *   401  no id_token cookie, or one that fails verification (signature, issuer,
 *        audience, expiry) — the browser's say-so is never an identity
 *   400  requestId missing or not a UUID
 *   200  AuditTraceResponse — rows only where the request ID was approved by the
 *        signed-in user; another user's request ID gets the same empty "pending"
 *        answer as a request whose records have not landed yet
 *   503  IVIA, Vault or Athena could not be reached or refused; the body names which
 *
 * Nothing here returns or logs a token or an AWS key: the id_token is only verified,
 * and the audit-reader keys stay inside the AWS SDK client.
 */

import { json, type RequestHandler } from '@sveltejs/kit';
import { REQUEST_ID_PATTERN, auditTraceStatus, type AuditTraceErrorResponse, type AuditTraceResponse } from '$lib/audit-trace';
import { AuditQueryError, queryAuditCorrelation } from '$lib/server/audit-trace/athena';
import { SessionError, verifySession } from '$lib/server/audit-trace/session';

const NO_STORE = { 'Cache-Control': 'no-store' };

function fail(status: number, error: string) {
	return json({ error } satisfies AuditTraceErrorResponse, { status, headers: NO_STORE });
}

const SESSION_MESSAGES: Record<SessionError['failure'], [number, string]> = {
	no_session: [401, 'Not signed in'],
	expired: [401, 'Your sign-in has expired — sign in again'],
	invalid: [401, 'Your sign-in could not be verified — sign in again'],
	unavailable: [503, 'Cannot reach IBM Verify Identity Access to check your sign-in'],
	misconfigured: [503, 'The banking UI is not configured to check sign-ins (IVIA_BASE_URL, IVIA_CLIENT_ID)']
};

const QUERY_MESSAGES: Record<AuditQueryError['failure'], string> = {
	misconfigured: 'The banking UI is not configured to query the audit trail',
	credentials: 'Could not get audit-reader keys from Vault',
	denied: 'The audit-reader role was refused by Athena',
	failed: 'The audit query failed',
	timeout: 'The audit query took too long'
};

export const GET: RequestHandler = async ({ url, cookies }) => {
	let sub: string;
	try {
		({ sub } = await verifySession(cookies.get('id_token')));
	} catch (err) {
		if (err instanceof SessionError) {
			const [status, message] = SESSION_MESSAGES[err.failure];
			return fail(status, message);
		}
		return fail(503, SESSION_MESSAGES.unavailable[1]);
	}

	const requestId = url.searchParams.get('requestId') ?? '';
	if (!REQUEST_ID_PATTERN.test(requestId)) {
		return fail(400, 'requestId must be the request ID of a Use Case 3 turn');
	}

	try {
		const rows = await queryAuditCorrelation(requestId, sub);
		const body: AuditTraceResponse = {
			requestId,
			status: auditTraceStatus(rows),
			rows,
			queriedAt: Date.now()
		};
		return json(body, { headers: NO_STORE });
	} catch (err) {
		const failure = err instanceof AuditQueryError ? err.failure : 'failed';
		// The detail names the step that failed (a Vault error string, an Athena state
		// reason) and never a credential; it is what an attendee needs to fix a deploy.
		const detail = err instanceof Error ? err.message : String(err);
		return fail(503, `${QUERY_MESSAGES[failure]}: ${detail}`);
	}
};
