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
 * returns the agent's JSON answer. Cross-namespace egress on port 80 is
 * permitted by the banking-ui-egress NetworkPolicy.
 */
import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';

const UC1_AGENT_URL = env.UC1_AGENT_URL ?? 'http://uc1-agent-svc.uc1.svc.cluster.local';

export const POST: RequestHandler = async ({ request }) => {
	let query = '';
	try {
		const body = await request.json();
		query = (body?.query ?? '').toString().trim();
	} catch {
		return new Response(JSON.stringify({ error: 'Invalid JSON body' }), { status: 400 });
	}

	if (!query) {
		return new Response(JSON.stringify({ error: 'query is required' }), { status: 400 });
	}

	let agentRes: Response;
	try {
		agentRes = await fetch(`${UC1_AGENT_URL}/query`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ query })
		});
	} catch (err) {
		return new Response(
			JSON.stringify({ error: `Cannot reach Use Case 1 agent: ${err instanceof Error ? err.message : String(err)}` }),
			{ status: 502 }
		);
	}

	if (!agentRes.ok) {
		const text = await agentRes.text();
		return new Response(JSON.stringify({ error: `Agent error [${agentRes.status}]: ${text}` }), {
			status: agentRes.status
		});
	}

	// uc1-agent returns { answer, sources, credential_metadata }. Pass it through.
	const data = await agentRes.json();
	return new Response(JSON.stringify(data), {
		headers: { 'Content-Type': 'application/json' }
	});
};
