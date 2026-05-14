import type { RequestHandler } from '@sveltejs/kit';
import { getConsent, storeConsent } from '$lib/ciba-store';

export const GET: RequestHandler = async ({ url }) => {
	const authReqId = url.searchParams.get('auth_req_id');
	const statusUrl = url.searchParams.get('status_url');
	const token = url.searchParams.get('token');
	const user = url.searchParams.get('user');

	console.log(`[ciba-check-status] CALLED — auth_req_id=${authReqId} status_url=${statusUrl ? 'present' : 'missing'} token=${token ? 'present' : 'missing'} user=${user}`);

	if (authReqId && statusUrl && token) {
		storeConsent(authReqId, { update_url: statusUrl, token, user: user ?? 'unknown' });
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
