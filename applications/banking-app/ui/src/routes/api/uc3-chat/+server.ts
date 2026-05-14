import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';

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
		const text = await agentRes.text();
		return new Response(JSON.stringify({ error: `UC3 agent error [${agentRes.status}]: ${text}` }), {
			status: agentRes.status,
		});
	}

	return new Response(agentRes.body, {
		headers: {
			'Content-Type': 'text/event-stream',
			'Cache-Control': 'no-cache',
			Connection: 'keep-alive',
			'X-Accel-Buffering': 'no',
		},
	});
};
