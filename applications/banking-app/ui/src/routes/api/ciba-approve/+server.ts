import type { RequestHandler } from '@sveltejs/kit';
import { getConsent, removeConsent } from '$lib/ciba-store';

export const POST: RequestHandler = async ({ request, cookies }) => {
	const idToken = cookies.get('id_token');
	if (!idToken) {
		return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
	}

	const body = await request.json();
	const { auth_req_id } = body;

	if (!auth_req_id) {
		return new Response(JSON.stringify({ error: 'Missing auth_req_id' }), { status: 400 });
	}

	const consent = getConsent(auth_req_id);
	if (!consent) {
		return new Response(
			JSON.stringify({ error: 'No pending consent for this auth_req_id — IVIA callback may not have arrived yet' }),
			{ status: 404 }
		);
	}

	process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

	const res = await fetch(consent.update_url, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Authorization: `Bearer ${consent.token}`,
		},
		body: JSON.stringify({
			status: 'success',
			metadata: {
				sAMAccountName: consent.user,
				uid: consent.user,
				sub: consent.user,
			},
		}),
	});

	removeConsent(auth_req_id);

	if (res.ok) {
		return new Response(JSON.stringify({ approved: true, auth_req_id }));
	}

	const errText = await res.text();
	return new Response(
		JSON.stringify({ error: `IVIA status_update failed: ${res.status}`, detail: errText }),
		{ status: res.status }
	);
};
