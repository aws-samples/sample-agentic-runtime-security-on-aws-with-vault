import { json, type RequestHandler } from '@sveltejs/kit';
import { sessionEndedBody } from '$lib/session-ended';
import { env } from '$env/dynamic/private';
import { scrubErrorText } from '$lib/server/activity-filter';
import { AgentCall, agentFailed, streamAgentEvents } from '$lib/server/agent-proxy';

const AGENT_URL = env.AGENT_URL ?? 'http://banking-agent-svc:3002';

export const POST: RequestHandler = async ({ request, cookies, platform }) => {
	// Forward the ACCESS token, not the id_token. Vault's native Agent-Registry
	// OBO resolves the acting agent from the `act.sub` claim (act.sub=agent-uc2),
	// which IVIA stamps onto the access token only (isvaop_pretoken rule). The
	// id_token carries no `act` claim, so presenting it yields a null identity and
	// Vault denies the database-creds read. See verify_access/iviaop-config/rules.yaml.
	const accessToken = cookies.get('access_token');
	if (!accessToken) {
		// No sign-in cookie left (both expire with their tokens): the same marked 401 the
		// hook sends, so the open page goes to sign-in instead of showing an error.
		return json(sessionEndedBody('unverifiable'), { status: 401, headers: { 'Cache-Control': 'no-store' } });
	}

	let body: unknown;
	try {
		body = await request.json();
	} catch {
		return json({ error: 'Invalid JSON body' }, { status: 400 });
	}

	// Closes the agent call when the browser leaves or the agent goes quiet.
	// See $lib/server/agent-proxy.
	const call = new AgentCall(request, platform);
	let agentRes: Response;
	try {
		agentRes = await fetch(`${AGENT_URL}/chat`, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Authorization: `Bearer ${accessToken}`,
			},
			body: JSON.stringify(body),
			signal: call.signal,
		});
	} catch (err) {
		call.end();
		return agentFailed(
			call,
			'Use Case 2',
			`Cannot reach the Use Case 2 agent: ${err instanceof Error ? err.message : String(err)}`
		);
	}
	call.touch();

	if (!agentRes.ok) {
		// The agent can close the connection, or go quiet, part-way through its error body.
		const errorBody = await call.readText(agentRes).catch(() => null);
		if (errorBody === null && call.stopped === 'agent_idle') {
			return agentFailed(call, 'Use Case 2', '');
		}
		const text = scrubErrorText(errorBody ?? '(the agent closed the connection before its error body arrived)');
		return json({ error: `Agent error [${agentRes.status}]: ${text}` }, { status: agentRes.status });
	}

	if (!agentRes.body) {
		call.end();
		return json({ error: 'Agent returned no response body' }, { status: 502 });
	}

	// Every event the agent streams passes through the activity filter: the
	// browser never receives the agent's bytes directly. See $lib/server/activity-filter.
	return streamAgentEvents(call, agentRes.body, 'api/chat', 'Use Case 2');
};
