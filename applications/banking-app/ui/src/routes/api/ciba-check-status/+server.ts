import type { RequestHandler } from '@sveltejs/kit';
import { getConsent, storeConsent } from '$lib/ciba-store';

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

export const GET: RequestHandler = async ({ url, cookies }) => {
	const idToken = cookies.get('id_token');
	if (!idToken) {
		return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
	}

	const approverSub = decodeJwtSub(idToken);
	if (!approverSub) {
		return new Response(JSON.stringify({ error: 'Invalid or malformed id_token' }), { status: 401 });
	}

	const authReqId = url.searchParams.get('auth_req_id');
	const statusUrl = url.searchParams.get('status_url');
	const token = url.searchParams.get('token');

	console.log(`[ciba-check-status] CALLED — auth_req_id=${authReqId} status_url=${statusUrl ? 'present' : 'missing'} token=${token ? 'present' : 'missing'} sub=${approverSub}`);

	if (authReqId && statusUrl && token) {
		storeConsent(authReqId, { update_url: statusUrl, token, user: approverSub });
		console.log(`[ciba-check-status] Stored consent data for ${authReqId}`);
	}

	const consent = authReqId ? getConsent(authReqId) : null;
	const approved = consent && (consent as any).approved === true;

	return new Response(JSON.stringify({
		auth_req_id: authReqId,
		status: approved ? 'SUCCEEDED' : 'PENDING',
	}), {
		status: 200,
		headers: { 'Content-Type': 'application/json' },
	});
};
