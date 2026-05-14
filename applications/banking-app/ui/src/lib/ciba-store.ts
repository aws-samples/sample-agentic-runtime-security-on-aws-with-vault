const pendingConsents = new Map<string, { update_url: string; token: string; user: string; received_at: number }>();

export function storeConsent(authReqId: string, data: { update_url: string; token: string; user: string }) {
	pendingConsents.set(authReqId, { ...data, received_at: Date.now() });

	const cutoff = Date.now() - 15 * 60 * 1000;
	for (const [key, val] of pendingConsents) {
		if (val.received_at < cutoff) pendingConsents.delete(key);
	}
}

export function getConsent(authReqId: string) {
	return pendingConsents.get(authReqId) ?? null;
}

export function removeConsent(authReqId: string) {
	pendingConsents.delete(authReqId);
}
