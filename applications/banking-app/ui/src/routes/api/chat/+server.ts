import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { filteredEventStream, scrubErrorText } from '$lib/server/activity-filter';

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

	let body: unknown;
	try {
		body = await request.json();
	} catch {
		return new Response(JSON.stringify({ error: 'Invalid JSON body' }), { status: 400 });
	}

	let agentRes: Response;
	try {
		agentRes = await fetch(`${AGENT_URL}/chat`, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Authorization: `Bearer ${accessToken}`,
			},
			body: JSON.stringify(body),
		});
	} catch (err) {
		return new Response(
			JSON.stringify({ error: `Cannot reach the Use Case 2 agent: ${err instanceof Error ? err.message : String(err)}` }),
			{ status: 502 }
		);
	}

	if (!agentRes.ok) {
		const text = scrubErrorText(await agentRes.text());
		return new Response(JSON.stringify({ error: `Agent error [${agentRes.status}]: ${text}` }), {
			status: agentRes.status,
		});
	}

	if (!agentRes.body) {
		return new Response(JSON.stringify({ error: 'Agent returned no response body' }), { status: 502 });
	}

	// Every event the agent streams passes through the activity filter: the
	// browser never receives the agent's bytes directly. See $lib/server/activity-filter.
	return filteredEventStream(agentRes.body, 'api/chat');
};
