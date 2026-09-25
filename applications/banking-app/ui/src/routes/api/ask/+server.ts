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
import { scrubErrorText, scrubJson } from '$lib/server/activity-filter';
import { AgentCall, agentFailed, streamAgentEvents } from '$lib/server/agent-proxy';

const UC1_AGENT_URL = env.UC1_AGENT_URL ?? 'http://uc1-agent-svc.uc1.svc.cluster.local';

export const POST: RequestHandler = async ({ request, platform }) => {
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

	// Closes the agent call when the browser leaves or the agent goes quiet.
	// See $lib/server/agent-proxy.
	const call = new AgentCall(request, platform);
	let agentRes: Response;
	try {
		agentRes = await fetch(`${UC1_AGENT_URL}/query`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ query }),
			signal: call.signal
		});
	} catch (err) {
		call.end();
		return agentFailed(
			call,
			'Use Case 1',
			`Cannot reach Use Case 1 agent: ${err instanceof Error ? err.message : String(err)}`
		);
	}
	call.touch();

	if (!agentRes.ok) {
		// The agent can close the connection, or go quiet, part-way through its error body.
		const errorBody = await call.readText(agentRes).catch(() => null);
		if (errorBody === null && call.stopped === 'agent_idle') {
			return agentFailed(call, 'Use Case 1', '');
		}
		const text = scrubErrorText(errorBody ?? '(the agent closed the connection before its error body arrived)');
		return json({ error: `Agent error [${agentRes.status}]: ${text}` }, { status: agentRes.status });
	}

	// A streaming agent goes through the same activity filter as the other two
	// chats. The media type may carry parameters (e.g. "; charset=utf-8").
	const contentType = (agentRes.headers.get('content-type') ?? '').toLowerCase();
	if (contentType.startsWith('text/event-stream')) {
		if (!agentRes.body) {
			call.end();
			return json({ error: 'Agent returned no response body' }, { status: 502 });
		}
		return streamAgentEvents(call, agentRes.body, 'api/ask', 'Use Case 1');
	}

	// Otherwise uc1-agent returns JSON { answer, sources, credential_metadata }.
	// The filter's payload key rules apply to it before it reaches the browser.
	let data: unknown;
	try {
		data = JSON.parse(await call.readText(agentRes));
	} catch {
		return agentFailed(call, 'Use Case 1', 'Use Case 1 agent returned a body that is not JSON');
	}
	return new Response(JSON.stringify(scrubJson(data) ?? null), {
		headers: { 'Content-Type': 'application/json' }
	});
};
