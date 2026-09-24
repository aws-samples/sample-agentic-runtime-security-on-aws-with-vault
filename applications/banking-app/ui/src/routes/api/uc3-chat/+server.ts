import { json, type RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { scrubErrorText } from '$lib/server/activity-filter';
import { AgentCall, agentFailed, streamAgentEvents } from '$lib/server/agent-proxy';

const UC3_AGENT_URL = env.UC3_AGENT_URL ?? 'http://uc3-agent-svc:8080';

export const POST: RequestHandler = async ({ request, cookies, platform }) => {
	const idToken = cookies.get('id_token');
	if (!idToken) {
		return json({ error: 'Not authenticated' }, { status: 401 });
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
		agentRes = await fetch(`${UC3_AGENT_URL}/chat`, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Authorization: `Bearer ${idToken}`,
			},
			body: JSON.stringify(body),
			signal: call.signal,
		});
	} catch (err) {
		call.end();
		return agentFailed(
			call,
			'Use Case 3',
			`Cannot reach the Use Case 3 agent: ${err instanceof Error ? err.message : String(err)}`
		);
	}

	if (!agentRes.ok) {
		// The agent can close the connection, or go quiet, part-way through its error body.
		const errorBody = await call.readText(agentRes).catch(() => null);
		if (errorBody === null && call.stopped === 'agent_idle') {
			return agentFailed(call, 'Use Case 3', '');
		}
		const text = scrubErrorText(errorBody ?? '(the agent closed the connection before its error body arrived)');
		return json({ error: `UC3 agent error [${agentRes.status}]: ${text}` }, { status: agentRes.status });
	}

	if (!agentRes.body) {
		call.end();
		return json({ error: 'UC3 agent returned no response body' }, { status: 502 });
	}

	// Every event the agent streams passes through the activity filter: the
	// browser never receives the agent's bytes directly. See $lib/server/activity-filter.
	return streamAgentEvents(call, agentRes.body, 'api/uc3-chat', 'Use Case 3');
};
