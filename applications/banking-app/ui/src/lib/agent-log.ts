/**
 * agent-log.ts — the lines the Agent Log shows for one chat turn.
 *
 * logLines(turn) turns the agent events a Turn holds ($lib/turn-events.svelte)
 * into what the panel prints, in arrival order. It is pure: same events, same
 * lines. Nothing an event carries is hidden or shortened here; the panel decides
 * how much of a long tool output to show before "Show all".
 *
 *   agent:thinking     ▶ Agent: <text>            (a repeat of the line before it is skipped)
 *   agent:narration ▶  ▶ Agent: <text>
 *   agent:narration ⚡  ⚡ <label>: <text>          (tool output and other reported data)
 *   tool_call          ▶ Agent: I need to call the tool — <name>   (skipped when the agent
 *                        narrated exactly that line just before, as Use Case 2 does)
 *                      ⚡ Tool "<name>" output: <result>  /  Tool "<name>" failed: <result>
 *   agent:hitl_*       ▶ Agent: <text>, then ⚡ Approval details: <details> when present
 *   agent:credential   ⚡ Credential <issued|presented|reused> · <kind>: <issuer · path>
 *                        with the value or its parts in full, and a line of metadata
 *   agent:error        ⚡ Error: <message>
 *
 * agent:text_delta (the answer, shown in the chat), agent:audit_seed (the Audit
 * Trace's key) and agent:done carry no step of their own and print nothing.
 */

import type { AgentCredentialEvent, AgentEvent, CredentialKind, JsonValue } from '$lib/agent-events';
import type { Turn } from '$lib/turn-events.svelte';

export interface CredentialView {
	/** issued: made for this turn; presented: shown to someone to prove who is asking; reused: made earlier. */
	verb: 'issued' | 'presented' | 'reused';
	/** e.g. "Vault token". */
	kindLabel: string;
	/** Who issued it and where from, e.g. "Vault · database/creds/uc1-readonly". */
	source: string;
	/** The agent's own plain-English label for it. */
	label: string;
	/** The whole token, for a single-value credential. */
	value?: string;
	/** Every part of a multi-part credential, in the order the agent sent them. */
	fields?: [string, string][];
	/** What the Copy button copies: the value, or one `name=value` line per part. */
	copyText?: string;
	/** Short facts about it: decoded claims, lease, lifetime, expiry. */
	meta: string[];
}

export type LogLine =
	| { kind: 'step'; text: string }
	| { kind: 'output'; label: string; text: string }
	| { kind: 'error'; label: string; text: string }
	| { kind: 'credential'; credential: CredentialView };

const KIND_LABELS: Record<CredentialKind, string> = {
	access_token: 'access token',
	id_token: 'ID token',
	refresh_token: 'refresh token',
	ciba_token: 'CIBA token',
	delegated_token: 'delegated token (RFC 8693)',
	k8s_sa_token: 'Kubernetes service-account token',
	vault_token: 'Vault token',
	db_credentials: 'database credentials',
	aws_sts_credentials: 'AWS STS credentials'
};

/** Tokens a caller shows to prove who is asking, rather than receives. */
const PRESENTED_KINDS: ReadonlySet<CredentialKind> = new Set(['access_token', 'id_token', 'refresh_token', 'k8s_sa_token']);

const HITL_DEFAULT_TEXT = {
	'agent:hitl_required': 'Waiting for approval.',
	'agent:hitl_approved': 'Approved.',
	'agent:hitl_denied': 'Denied.',
	'agent:hitl_timeout': 'No approval arrived in time.'
} as const;

/** JSON on one line, as the agent sent it. A bare string is shown without quotes. */
export function jsonText(value: JsonValue | undefined): string {
	if (value === undefined) return '';
	if (typeof value === 'string') return value;
	return JSON.stringify(value);
}

/** Wall-clock time of an epoch-milliseconds instant, e.g. "14:03:27". */
export function clockTime(epochMs: number): string {
	return new Date(epochMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
}

function credentialView(event: AgentCredentialEvent): CredentialView {
	const kind = event.kind;
	const reused = /\breused\b/i.test(event.label ?? '');
	const verb: CredentialView['verb'] = reused ? 'reused' : PRESENTED_KINDS.has(kind) ? 'presented' : 'issued';
	const source = [event.issuer, event.vaultPath].filter((part) => typeof part === 'string' && part !== '').join(' · ');

	const fields =
		event.fields && typeof event.fields === 'object'
			? Object.entries(event.fields).map(([name, part]): [string, string] => [name, String(part)])
			: undefined;
	const value = typeof event.value === 'string' ? event.value : undefined;
	const copyText = value ?? (fields && fields.length > 0 ? fields.map(([name, part]) => `${name}=${part}`).join('\n') : undefined);

	const meta: string[] = [];
	const claims = event.claims && typeof event.claims === 'object' && !Array.isArray(event.claims) ? event.claims : undefined;
	if (claims) {
		meta.push('decoded');
		if (typeof claims.sub === 'string') meta.push(`sub ${claims.sub}`);
		if (typeof claims.scope === 'string') meta.push(claims.scope);
		if (typeof claims.exp === 'number') meta.push(`exp ${clockTime(claims.exp * 1000)}`);
	}
	if (event.leaseId) meta.push(`lease ${event.leaseId}`);
	if (typeof event.ttlSeconds === 'number') meta.push(`${event.ttlSeconds}s`);
	if (typeof event.expiresAt === 'number' && !(claims && typeof claims.exp === 'number')) {
		meta.push(`expires ${clockTime(event.expiresAt)}`);
	}

	return {
		verb,
		kindLabel: KIND_LABELS[kind] ?? String(kind),
		source,
		label: event.label ?? '',
		value,
		fields,
		copyText,
		meta
	};
}

/** Splits "Response credential_metadata: {...}" into its label and its data. */
function splitLabel(text: string): { label: string; text: string } {
	const at = text.indexOf(': ');
	if (at > 0 && at < 80 && !text.slice(0, at).includes('\n')) {
		return { label: text.slice(0, at + 2), text: text.slice(at + 2) };
	}
	return { label: '', text };
}

/** Every line the Agent Log shows for `turn`, in arrival order. */
export function logLines(turn: Pick<Turn, 'events'>): LogLine[] {
	const lines: LogLine[] = [];
	let previous: AgentEvent | undefined;

	for (const event of turn.events) {
		switch (event.type) {
			case 'agent:thinking': {
				const text = event.text || 'Thinking…';
				const last = lines.at(-1);
				if (!(last?.kind === 'step' && last.text === text)) lines.push({ kind: 'step', text });
				break;
			}
			case 'agent:narration':
				if (event.glyph === '⚡') lines.push({ kind: 'output', ...splitLabel(event.text) });
				else lines.push({ kind: 'step', text: event.text });
				break;
			case 'tool_call': {
				if (event.status === 'in_progress') {
					const text = `I need to call the tool — ${event.name}`;
					const narratedAlready = previous?.type === 'agent:narration' && previous.text === text;
					if (!narratedAlready) lines.push({ kind: 'step', text });
				} else if (event.status === 'success') {
					lines.push({ kind: 'output', label: `Tool "${event.name}" output: `, text: jsonText(event.result) });
				} else {
					lines.push({
						kind: 'error',
						label: `Tool "${event.name}" failed: `,
						text: jsonText(event.result) || 'the agent reported no detail'
					});
				}
				break;
			}
			case 'agent:hitl_required':
			case 'agent:hitl_approved':
			case 'agent:hitl_denied':
			case 'agent:hitl_timeout':
				lines.push({ kind: 'step', text: event.text || HITL_DEFAULT_TEXT[event.type] });
				if (event.details && Object.keys(event.details).length > 0) {
					lines.push({ kind: 'output', label: 'Approval details: ', text: jsonText(event.details) });
				}
				break;
			case 'agent:credential':
				lines.push({ kind: 'credential', credential: credentialView(event) });
				break;
			case 'agent:error':
				lines.push({ kind: 'error', label: 'Error: ', text: event.message });
				break;
			default:
				// agent:text_delta, agent:audit_seed, agent:done: nothing to print.
				break;
		}
		previous = event;
	}
	return lines;
}

/** How many lines the Agent Log shows for all of `turns`: the badge and footer count. */
export function countEntries(turns: readonly Pick<Turn, 'events'>[]): number {
	let count = 0;
	for (const turn of turns) count += logLines(turn).length;
	return count;
}
