/**
 * session-ended.ts — the 401 that says a sign-in is over, and what the browser does with it.
 *
 * hooks.server.ts answers a request under /api/ (other than the public /api/ask) whose
 * ID token has expired, is missing or cannot be read with 401 and a SessionEndedBody.
 * The browser code that calls those routes sends the person to sign in when it gets one:
 * lib/agent-client.ts for the Banking Agent and refund chats, and the Audit Trace card.
 * That is a full navigation to /, which starts sign-in, so no page stays on screen
 * looking signed in once its session has ended.
 *
 * Only this 401 does that. Any other failure, including another route's own 401 (for
 * example an agent refusing a token), is shown as an error, as before.
 *
 * Shared by the server and the browser, so it imports nothing.
 */

/** Why the sign-in ended: its ID token expired, or it is missing or unreadable. */
export type SessionEndReason = 'expired' | 'unverifiable';

/** The body of the 401 hooks.server.ts sends when a sign-in has ended. */
export interface SessionEndedBody {
	/** A sentence for the person. */
	error: string;
	/** The marker the browser acts on. */
	sessionEnded: SessionEndReason;
}

const SESSION_END_MESSAGES: Record<SessionEndReason, string> = {
	expired: 'Your sign-in has expired — sign in again',
	unverifiable: 'Your sign-in could not be verified — sign in again'
};

export function sessionEndedBody(reason: SessionEndReason): SessionEndedBody {
	return { error: SESSION_END_MESSAGES[reason], sessionEnded: reason };
}

/**
 * Whether a response is the session-ended 401. `body` is the response body, either as
 * text or already parsed from JSON.
 */
export function isSessionEnded(status: number, body: unknown): boolean {
	if (status !== 401) return false;
	let value = body;
	if (typeof value === 'string') {
		try {
			value = JSON.parse(value);
		} catch {
			return false;
		}
	}
	if (!value || typeof value !== 'object') return false;
	const reason = (value as { sessionEnded?: unknown }).sessionEnded;
	return reason === 'expired' || reason === 'unverifiable';
}

/** Leave this page for sign-in: a full navigation to /, which starts it. */
export function goToSignIn(): void {
	window.location.assign('/');
}
