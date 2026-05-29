import type { RequestHandler } from '@sveltejs/kit';
import { storeConsent } from '$lib/ciba-store';

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
	const { auth_req_id, update_url, token } = body;

	if (!auth_req_id || !update_url || !token) {
		return new Response(JSON.stringify({ error: 'Missing required fields' }), { status: 400 });
	}

	storeConsent(auth_req_id, { update_url, token, user: approverSub });

	return new Response(JSON.stringify({ stored: true, auth_req_id }), { status: 200 });
};
