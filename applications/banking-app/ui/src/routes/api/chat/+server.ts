import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';

const AGENT_URL = env.AGENT_URL ?? 'http://banking-agent-svc:3002';

export const POST: RequestHandler = async ({ request, cookies }) => {
	// Forward the ACCESS token, not the id_token. Vault's native Agent-Registry
	// OBO resolves the acting agent from the `act.sub` claim (act.sub=agent-uc2),
	// which IVIA stamps onto the access token only (isvaop_pretoken rule). The
	// id_token carries no `act` claim, so presenting it yields a null identity and
	// Vault denies the database-creds read. See verify_access/iviaop-config/rules.yaml.
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
