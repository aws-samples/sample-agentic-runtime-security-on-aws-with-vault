import type { RequestHandler } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';

const IVIA_BASE_URL = env.IVIA_BASE_URL ?? 'https://isvaop.verify-access.svc.cluster.local:8436';
const UC3_CLIENT_ID = env.UC3_IVIA_CLIENT_ID ?? 'agent-uc3';
const UC3_CLIENT_SECRET = env.UC3_IVIA_CLIENT_SECRET ?? '';

export const POST: RequestHandler = async ({ request, cookies }) => {
	const idToken = cookies.get('id_token');
	if (!idToken) {
		return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
	}

	let username = 'unknown';
	try {
		const parts = idToken.split('.');
		if (parts.length === 3) {
			const payload = JSON.parse(atob(parts[1]));
			username = payload.preferred_username ?? payload.sub ?? 'unknown';
		}
	} catch { /* use default */ }

	const body = await request.json();
	const { auth_req_id } = body;

	if (!auth_req_id) {
		return new Response(JSON.stringify({ error: 'Missing auth_req_id' }), { status: 400 });
	}

	const statusUrl = `${IVIA_BASE_URL}/oauth2/ciba_status_update/${auth_req_id}`;

	// IVIA uses a self-signed cert in the workshop; skip TLS verification.
	// Production deployments should use a proper CA chain.
	process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

	const res = await fetch(statusUrl, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Authorization: `Basic ${btoa(`${UC3_CLIENT_ID}:${UC3_CLIENT_SECRET}`)}`,
		},
		body: JSON.stringify({
			status: 'approve',
			subject: username,
		}),
	});

	if (res.ok) {
		return new Response(JSON.stringify({ approved: true, auth_req_id }));
	}

	const errText = await res.text();
	return new Response(
		JSON.stringify({ error: `IVIA status_update failed: ${res.status}`, detail: errText }),
		{ status: res.status }
	);
};
