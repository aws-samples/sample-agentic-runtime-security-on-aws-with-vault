/**
 * /api/ask — public proxy to the Use Case 1 agent.
 *
 * This endpoint is intentionally unauthenticated: Use Case 1 demonstrates a
 * non-personalized, read-only agent whose access is governed entirely by
 * workload identity (Kubernetes SA JWT -> Vault JIT credentials), NOT by any
 * end-user token. There is no Authorization header to forward — the uc1-agent
 * authenticates itself to Vault.
 *
 * The browser POSTs { query } here; this server-side handler (running in the
 * banking-ui pod) forwards it to the uc1-agent-svc in the uc1 namespace and
 * returns the agent's answer through $lib/server/activity-filter: an SSE reply
 * is streamed through the filter, a JSON reply loses its configuration-secret keys.
 * Cross-namespace egress on port 80 is permitted by the banking-ui-egress
 * NetworkPolicy.
 */
import { json, type RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { filteredEventStream, scrubErrorText, scrubJson } from '$lib/server/activity-filter';

const UC1_AGENT_URL = env.UC1_AGENT_URL ?? 'http://uc1-agent-svc.uc1.svc.cluster.local';

export const POST: RequestHandler = async ({ request }) => {
	let query = '';
	try {
		const body = await request.json();
		query = (body?.query ?? '').toString().trim();
	} catch {
		return json({ error: 'Invalid JSON body' }, { status: 400 });
	}

	if (!query) {
		return json({ error: 'query is required' }, { status: 400 });
	}

	let agentRes: Response;
	try {
		agentRes = await fetch(`${UC1_AGENT_URL}/query`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ query })
		});
	} catch (err) {
		return json(
			{ error: `Cannot reach Use Case 1 agent: ${err instanceof Error ? err.message : String(err)}` },
			{ status: 502 }
		);
	}

	if (!agentRes.ok) {
		// The agent can close the connection part-way through its error body.
		const errorBody = await agentRes.text().catch(() => '(the agent closed the connection before its error body arrived)');
		const text = scrubErrorText(errorBody);
		return json({ error: `Agent error [${agentRes.status}]: ${text}` }, { status: agentRes.status });
	}

	// A streaming agent goes through the same activity filter as the other two
	// chats. The media type may carry parameters (e.g. "; charset=utf-8").
	const contentType = (agentRes.headers.get('content-type') ?? '').toLowerCase();
	if (contentType.startsWith('text/event-stream')) {
		if (!agentRes.body) {
			return json({ error: 'Agent returned no response body' }, { status: 502 });
		}
		return filteredEventStream(agentRes.body, 'api/ask');
	}

	// Otherwise uc1-agent returns JSON { answer, sources, credential_metadata }.
	// The filter's payload key rules apply to it before it reaches the browser.
	let data: unknown;
	try {
		data = await agentRes.json();
	} catch {
		return json({ error: 'Use Case 1 agent returned a body that is not JSON' }, { status: 502 });
	}
	return new Response(JSON.stringify(scrubJson(data) ?? null), {
		headers: { 'Content-Type': 'application/json' }
	});
};
