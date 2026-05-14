import type { RequestHandler } from '@sveltejs/kit';
import { storeConsent } from '$lib/ciba-store';

export const POST: RequestHandler = async ({ request }) => {
	const body = await request.json();
	const { auth_req_id, update_url, token, user } = body;

	if (!auth_req_id || !update_url || !token) {
		return new Response(JSON.stringify({ error: 'Missing required fields' }), { status: 400 });
	}

	storeConsent(auth_req_id, { update_url, token, user: user ?? 'unknown' });

	return new Response(JSON.stringify({ stored: true, auth_req_id }), { status: 200 });
};
