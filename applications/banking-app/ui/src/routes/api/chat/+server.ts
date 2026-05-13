import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';

const AGENT_URL = env.AGENT_URL ?? 'http://banking-agent-svc:3002';

export const POST: RequestHandler = async ({ request, cookies }) => {
	const accessToken = cookies.get('access_token');
	if (!accessToken) {
		return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
	}

	const body = await request.json();

	const agentRes = await fetch(`${AGENT_URL}/chat`, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Authorization: `Bearer ${accessToken}`,
		},
		body: JSON.stringify(body),
	});

	if (!agentRes.ok) {
		const text = await agentRes.text();
		return new Response(JSON.stringify({ error: `Agent error [${agentRes.status}]: ${text}` }), {
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
