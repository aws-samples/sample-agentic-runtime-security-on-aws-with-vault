/**
 * /api/ask — the Ask page's proxy to the Use Case 1 agent, streamed.
 *
 * Use Case 1 needs no sign-in: the uc1-agent's access is governed entirely by its
 * workload identity (Kubernetes service-account JWT -> Vault just-in-time
 * credentials), never by an end-user token. No Authorization header is forwarded;
 * the agent authenticates itself to Vault.
 *
 * The browser POSTs { query } (or { message }, as $lib/agent-client sends it).
 * This handler, in the banking-ui pod, asks uc1-agent-svc in the uc1 namespace for
 * a Server-Sent Events stream (Accept: text/event-stream) and relays it through
 * $lib/server/activity-filter, the same filter as the other two chats. Every
 * visitor, signed in or not, receives the whole stream: the answer, and each
 * credential the turn uses in full, as the agent sent it.
 *
 * An agent that answers with JSON instead (an image older than the stream) gets
 * the filter's payload structure rules (scrubJson) and nothing else; that reply
 * carries credential metadata, never a credential value.
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
		query = (body?.query ?? body?.message ?? '').toString().trim();
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
			headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream' },
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

	// The media type may carry parameters (e.g. "; charset=utf-8").
	const contentType = (agentRes.headers.get('content-type') ?? '').toLowerCase();
	if (contentType.startsWith('text/event-stream')) {
		if (!agentRes.body) {
			call.end();
			return json({ error: 'Agent returned no response body' }, { status: 502 });
		}
		return streamAgentEvents(call, agentRes.body, 'api/ask', 'Use Case 1');
	}

	// An agent that does not stream returns JSON { answer, sources, credential_metadata }.
	// The filter's payload structure rules apply to it before it reaches the browser.
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
