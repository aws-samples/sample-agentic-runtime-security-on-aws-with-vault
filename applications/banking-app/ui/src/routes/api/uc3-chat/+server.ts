import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { filteredEventStream, scrubErrorText } from '$lib/server/activity-filter';

const UC3_AGENT_URL = env.UC3_AGENT_URL ?? 'http://uc3-agent-svc:8080';

export const POST: RequestHandler = async ({ request, cookies }) => {
	const idToken = cookies.get('id_token');
	if (!idToken) {
		return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
	}

	const body = await request.json();

	const agentRes = await fetch(`${UC3_AGENT_URL}/chat`, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Authorization: `Bearer ${idToken}`,
		},
		body: JSON.stringify(body),
	});

	if (!agentRes.ok) {
		const text = scrubErrorText(await agentRes.text());
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
