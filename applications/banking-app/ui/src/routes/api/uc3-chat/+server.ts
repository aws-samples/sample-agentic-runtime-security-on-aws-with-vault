import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { filteredEventStream, scrubErrorText } from '$lib/server/activity-filter';

const UC3_AGENT_URL = env.UC3_AGENT_URL ?? 'http://uc3-agent-svc:8080';

export const POST: RequestHandler = async ({ request, cookies }) => {
	const idToken = cookies.get('id_token');
	if (!idToken) {
		return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
	}

	let body: unknown;
	try {
		body = await request.json();
	} catch {
		return new Response(JSON.stringify({ error: 'Invalid JSON body' }), { status: 400 });
	}

	let agentRes: Response;
	try {
		agentRes = await fetch(`${UC3_AGENT_URL}/chat`, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Authorization: `Bearer ${idToken}`,
			},
			body: JSON.stringify(body),
		});
	} catch (err) {
		return new Response(
			JSON.stringify({ error: `Cannot reach the Use Case 3 agent: ${err instanceof Error ? err.message : String(err)}` }),
			{ status: 502 }
		);
	}

	if (!agentRes.ok) {
		// The agent can close the connection part-way through its error body.
		const errorBody = await agentRes.text().catch(() => '(the agent closed the connection before its error body arrived)');
		const text = scrubErrorText(errorBody);
		return new Response(JSON.stringify({ error: `UC3 agent error [${agentRes.status}]: ${text}` }), {
			status: agentRes.status,
		});
	}

	if (!agentRes.body) {
		return new Response(JSON.stringify({ error: 'UC3 agent returned no response body' }), { status: 502 });
	}

	// Every event the agent streams passes through the activity filter: the
	// browser never receives the agent's bytes directly. See $lib/server/activity-filter.
	return filteredEventStream(agentRes.body, 'api/uc3-chat');
};
