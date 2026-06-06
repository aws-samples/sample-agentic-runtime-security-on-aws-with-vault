import type { RequestHandler } from '@sveltejs/kit';
import { getConsent, removeConsent } from '$lib/ciba-store';

/**
 * Decode the `sub` claim from the second segment of a JWT.
 * Returns null if the token is absent, malformed, or missing sub — caller must 401.
 */
function decodeJwtSub(token: string): string | null {
	try {
		const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString());
		const sub = payload.sub as string | undefined;
		return sub ?? null;
	} catch {
		return null;
	}
}

export const POST: RequestHandler = async ({ request, cookies }) => {
	const idToken = cookies.get('id_token');
	if (!idToken) {
		return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
	}

	const approverSub = decodeJwtSub(idToken);
	if (!approverSub) {
		return new Response(JSON.stringify({ error: 'Invalid or malformed id_token' }), { status: 401 });
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

	const res = await fetch(consent.update_url, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Authorization: `Bearer ${consent.token}`,
		},
		body: JSON.stringify({
			status: 'success',
			metadata: {
				sAMAccountName: approverSub,
				uid: approverSub,
				sub: approverSub,
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
