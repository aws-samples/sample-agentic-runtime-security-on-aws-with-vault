/**
 * audit-trace.ts — what the Audit Trace card shows, and the shape of GET /api/audit-trace.
 *
 * Issue #68 · Audit Trace card: each answer links to the audit records every system
 * wrote for it.
 *
 * Two sources:
 *   - Use Case 3, a refund that went through: the rows of Athena's audit_correlation
 *     view for the turn's request ID, fetched by the UI server
 *     (routes/api/audit-trace/+server.ts). One row joins three planes — the agent's
 *     approval anchor (ivia_decisions), Vault's audit record of the refund-writer
 *     credential (vault_audit) and Postgres pgaudit's record of the INSERT
 *     (pgaudit_logs) — on that one request ID. The rows land about 60 s after the
 *     refund (Firehose buffer).
 *   - Every other turn (Use Case 1, Use Case 2, a Use Case 3 turn with no refund): the
 *     live facts the turn's own events reported — Vault paths, leases, time-to-live,
 *     the kind of each credential and when it was issued. Athena has no request-ID
 *     join for those answers, so nothing is queried.
 *
 * The card never shows a credential's value, `fields` or anything beyond a handful of
 * non-secret claims (sub, the service account's name). The Agent Log shows values.
 *
 * Types and pure functions only, so browser code and the server route share them.
 */

import type { AgentAuditSeedEvent, AgentCredentialEvent, AgentEvent, JsonObject, JsonValue } from '$lib/agent-events';
// Type-only: the server route imports this file, and the store module uses Svelte runes.
import type { Turn } from '$lib/turn-events.svelte';
import { credentialVerb } from '$lib/agent-log';

// ---------------------------------------------------------------------------
// The endpoint's contract
// ---------------------------------------------------------------------------

/**
 * The audit_correlation view's columns, as infrastructure/modules/observability/main.tf
 * defines them. The endpoint selects exactly these, so a renamed column fails loudly
 * (COLUMN_NOT_FOUND) instead of reading as "no audit yet".
 */
export const AUDIT_CORRELATION_COLUMNS = [
	'request_id',
	'approval_time',
	'user_approved_sub',
	'ciba_binding_message',
	'vault_auth_time',
	'vault_principal',
	'vault_human_entity_id',
	'vault_agent_registry_id',
	'vault_rar_path',
	'db_write_time',
	'db_command',
	'db_credential_ttl'
] as const;
export type AuditCorrelationColumn = (typeof AUDIT_CORRELATION_COLUMNS)[number];

/** One audit_correlation row. Athena returns every value as text; a missing value is null. */
export type AuditCorrelationRow = Record<AuditCorrelationColumn, string | null>;

/**
 * pending  — no row yet: the audit records have not all reached Athena.
 * partial  — the approval anchor and Vault's record have joined; pgaudit's record of
 *            the write has not landed yet (the view LEFT JOINs it).
 * complete — all three planes are in.
 */
export type AuditTraceStatus = 'pending' | 'partial' | 'complete';

export interface AuditTraceResponse {
	requestId: string;
	status: AuditTraceStatus;
	rows: AuditCorrelationRow[];
	/** When the server ran the query: milliseconds since the Unix epoch. */
	queriedAt: number;
}

export interface AuditTraceErrorResponse {
	error: string;
}

/** A Use Case 3 request ID: the lower-case UUID the refund agent generates (uuid4). */
export const REQUEST_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function auditTraceStatus(rows: AuditCorrelationRow[]): AuditTraceStatus {
	if (rows.length === 0) return 'pending';
	return rows.some((row) => Boolean(row.db_write_time)) ? 'complete' : 'partial';
}

// ---------------------------------------------------------------------------
// The turn the card sits under: a chat page's Turn ($lib/turn-events.svelte)
// ---------------------------------------------------------------------------

export type AuditUseCase = 1 | 2 | 3;

// ---------------------------------------------------------------------------
// Rows the card lists: audit planes (Use Case 3) or live facts (every other turn)
// ---------------------------------------------------------------------------

export type AuditSource = 'agent' | 'vault' | 'postgres' | 'kubernetes' | 'ivia' | 'aws sts';

export interface AuditListRow {
	/** Stable key for the list. */
	key: string;
	source: AuditSource;
	/** Epoch milliseconds, or null when the record carries no readable time. */
	at: number | null;
	summary: string;
	/** The full record, shown when the row is opened. Never a credential value. */
	fields: Array<[string, string]>;
}

/**
 * The three planes' times come in three formats:
 *   agent anchor  2026-09-25T14:03:11.123456+00:00  (Python isoformat)
 *   Vault audit   2026-09-25T14:03:12.345678901Z    (RFC 3339, nanoseconds)
 *   pgaudit       2026-09-25 14:03:13 UTC           (Postgres log_line_prefix)
 * Fractions are cut to milliseconds before parsing; anything else is unreadable (null).
 */
export function parseAuditTime(text: string | null | undefined): number | null {
	if (!text) return null;
	const trimmed = text.trim();
	const pg = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) UTC$/.exec(trimmed);
	if (pg) return Date.parse(`${pg[1]}T${pg[2]}Z`);
	const iso = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$/.exec(trimmed);
	if (!iso) return null;
	const millis = (iso[2] ?? '').slice(0, 3).padEnd(3, '0');
	const parsed = Date.parse(`${iso[1]}.${millis}${iso[3]}`);
	return Number.isNaN(parsed) ? null : parsed;
}

function field(label: string, value: string | null | undefined): Array<[string, string]> {
	return value === null || value === undefined || value === '' ? [] : [[label, value]];
}

/** The last segment of a Vault path: database/creds/uc3-refund-writer -> uc3-refund-writer. */
function lastSegment(path: string | null | undefined): string {
	if (!path) return '';
	const parts = path.split('/');
	return parts[parts.length - 1] ?? '';
}

/**
 * The records one audit_correlation row joins, one per plane, in the order they happen.
 * The pgaudit record names its operation (WRITE,INSERT) but not its table:
 * pgaudit.log_relation is off. banking.refunds is the only table the uc3-refund-writer
 * role can write (its creation statements in modules/vault_config), so the summary names it.
 */
export function auditPlaneRows(row: AuditCorrelationRow, index = 0): AuditListRow[] {
	const out: AuditListRow[] = [
		{
			key: `${index}-agent`,
			source: 'agent',
			at: parseAuditTime(row.approval_time),
			summary: `refund anchor · request ${row.request_id ?? ''}`,
			fields: [
				...field('request_id', row.request_id),
				...field('approval_time', row.approval_time),
				...field('user_approved_sub', row.user_approved_sub),
				...field('ciba_binding_message', row.ciba_binding_message),
				...field('db_credential_ttl', row.db_credential_ttl)
			]
		},
		{
			key: `${index}-vault`,
			source: 'vault',
			at: parseAuditTime(row.vault_auth_time),
			summary: `credential issued · ${lastSegment(row.vault_rar_path)}`,
			fields: [
				...field('vault_auth_time', row.vault_auth_time),
				...field('vault_principal', row.vault_principal),
				...field('vault_human_entity_id', row.vault_human_entity_id),
				...field('vault_agent_registry_id', row.vault_agent_registry_id),
				...field('vault_rar_path', row.vault_rar_path)
			]
		}
	];
	if (row.db_write_time || row.db_command) {
		const operation = (row.db_command ?? '').split(',').pop() || 'write';
		out.push({
			key: `${index}-postgres`,
			source: 'postgres',
			at: parseAuditTime(row.db_write_time),
			summary: `${operation} banking.refunds · pgaudit`,
			fields: [...field('db_write_time', row.db_write_time), ...field('db_command', row.db_command)]
		});
	}
	return out;
}

/**
 * The audit stream for a set of audit_correlation rows: agent, Vault, Postgres, in the
 * order the view joins them. A refund with more than one pgaudit record comes back as
 * several rows that repeat the same agent and Vault columns, so each distinct record is
 * listed once.
 *
 * Not sorted by time: the three clocks do not order the planes truthfully. pgaudit
 * stamps whole seconds, so the INSERT reads as earlier than the credential it used,
 * and the agent writes its anchor after the refund is done (live refund
 * 790805b0-…: Vault 15:43:49.464, anchor 15:43:49.566, pgaudit 15:43:49).
 */
export function auditStreamRows(rows: AuditCorrelationRow[]): AuditListRow[] {
	const seen = new Set<string>();
	const out: AuditListRow[] = [];
	rows.forEach((row, index) => {
		for (const plane of auditPlaneRows(row, index)) {
			const identity = `${plane.source}|${JSON.stringify(plane.fields)}`;
			if (seen.has(identity)) continue;
			seen.add(identity);
			out.push(plane);
		}
	});
	return out;
}

// ---------------------------------------------------------------------------
// Facts read from the turn's own events
// ---------------------------------------------------------------------------

function isObject(value: JsonValue | undefined): value is JsonObject {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function text(value: JsonValue | undefined): string | undefined {
	if (typeof value === 'string' && value !== '') return value;
	if (typeof value === 'number' && Number.isFinite(value)) return String(value);
	return undefined;
}

function num(value: JsonValue | undefined): number | undefined {
	if (typeof value === 'number' && Number.isFinite(value)) return value;
	if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) return Number(value);
	return undefined;
}

const SOURCE_BY_ISSUER: Record<string, AuditSource> = {
	'IBM Verify Identity Access': 'ivia',
	Vault: 'vault',
	Kubernetes: 'kubernetes',
	'AWS STS (via Vault)': 'aws sts'
};

/**
 * What each credential kind is called in a row. The verb after it (reused, presented or
 * issued) is the Agent Log's own rule, credentialVerb in $lib/agent-log, so the card and
 * the log never disagree about what a turn did with a credential.
 */
const KIND_NOUN: Record<string, string> = {
	access_token: 'access token',
	id_token: 'ID token',
	refresh_token: 'refresh token',
	ciba_token: 'approval (CIBA) token',
	delegated_token: 'delegated token',
	k8s_sa_token: 'service-account token',
	vault_token: 'Vault token',
	db_credentials: 'database credential',
	aws_sts_credentials: 'AWS STS keys'
};

export function isAuditSeed(event: AgentEvent): event is AgentAuditSeedEvent {
	return event.type === 'agent:audit_seed';
}

export function isCredential(event: AgentEvent): event is AgentCredentialEvent {
	return event.type === 'agent:credential';
}

/** The refund tools; a refund tool's result carries the refund's request ID once it bound one. */
const REFUND_TOOL_NAMES = new Set(['initiate_refund', 'complete_refund']);

/**
 * The request ID the audit trail files a turn under (Bear's ruling on #68): the audit seed's;
 * else the one on a refund tool's result; else the first one the turn carried. A refund tool's
 * in_progress event goes out before the tool binds the refund's ID, so on a turn that listed
 * transactions first it carries the turn's own (applications/uc3-agent/app/activity.py,
 * _report_start and _report_finish); only its result names the refund. The Security Flow uses
 * this too, so the flow and the Audit Trace card name the same request.
 */
export function auditRequestId(events: readonly AgentEvent[]): string | undefined {
	const hasId = (e: AgentEvent) => typeof e.requestId === 'string' && e.requestId !== '';
	const seed = events.filter((e) => isAuditSeed(e) && hasId(e)).pop();
	const refundResult = events.find(
		(e) => e.type === 'tool_call' && e.status !== 'in_progress' && REFUND_TOOL_NAMES.has(e.name) && hasId(e)
	);
	return (seed ?? refundResult ?? events.find(hasId))?.requestId;
}

/**
 * The live facts of a turn: every credential it reported (metadata only — kind, issuer,
 * Vault path, lease, time-to-live, expiry) and every lease in its audit seed that no
 * credential event already showed.
 */
export function liveFactRows(events: AgentEvent[]): AuditListRow[] {
	const rows: AuditListRow[] = [];
	const leasesShown = new Set<string>();
	events.forEach((event, index) => {
		if (!isCredential(event)) return;
		if (event.leaseId) leasesShown.add(event.leaseId);
		const where = event.vaultPath ? ` · ${event.vaultPath}` : '';
		rows.push({
			key: `c${index}`,
			source: SOURCE_BY_ISSUER[event.issuer] ?? 'agent',
			at: typeof event.ts === 'number' ? event.ts : null,
			summary: `${KIND_NOUN[event.kind] ?? event.kind} ${credentialVerb(event)}${where}`,
			fields: [
				['kind', event.kind],
				['issuer', event.issuer],
				['label', event.label],
				...field('vault_path', event.vaultPath),
				...field('lease_id', event.leaseId),
				...field('ttl_seconds', event.ttlSeconds === undefined ? undefined : String(event.ttlSeconds)),
				...field('expires_at', event.expiresAt === undefined ? undefined : new Date(event.expiresAt).toISOString()),
				...field('request_id', event.requestId)
			]
		});
	});
	events.forEach((event, index) => {
		if (!isAuditSeed(event)) return;
		(event.leases ?? []).forEach((lease, leaseIndex) => {
			const leaseId = text(lease.lease_id);
			if (leaseId && leasesShown.has(leaseId)) return;
			const path = text(lease.vault_path);
			rows.push({
				key: `s${index}-${leaseIndex}`,
				source: 'vault',
				at: typeof event.ts === 'number' ? event.ts : null,
				summary: `lease · ${path ?? leaseId ?? 'unnamed'}`,
				fields: [
					...field('vault_path', path),
					...field('lease_id', leaseId),
					...field('ttl_seconds', text(lease.ttl_seconds)),
					...field('vault_role', event.vaultRole),
					...field('db_role', event.dbRole),
					...field('request_id', event.requestId)
				]
			});
		});
	});
	return rows.sort((a, b) => (a.at ?? Number.MAX_SAFE_INTEGER) - (b.at ?? Number.MAX_SAFE_INTEGER));
}

/** The facts the card's header and Use Case 3 panels are built from. */
export interface TurnAuditFacts {
	requestId?: string;
	seed?: AgentAuditSeedEvent;
	/** The human the turn acted for (the delegated or user token's `sub`). */
	sub?: string;
	/** Use Case 1's Kubernetes service account, from its service-account token's claims. */
	serviceAccount?: string;
	vaultRole?: string;
	dbRole?: string;
	/** The RAR type the delegated token carries, e.g. refund_approval. */
	authorizationType?: string;
	/** The delegated token's lifetime (exp - iat), in seconds. */
	delegatedTtlSeconds?: number;
	/** The approved refund terms, from the approval event's details. */
	amount?: number;
	currency?: string;
	accountId?: string;
	/** The refund-writer lease (Use Case 3) or the first lease the seed lists. */
	lease?: { vaultPath?: string; leaseId?: string; ttlSeconds?: number };
	/** Turn length in milliseconds, when its start and last event are known. */
	durationMs?: number;
}

function serviceAccountName(claims: JsonObject | undefined): string | undefined {
	if (!claims) return undefined;
	const k8s = claims['kubernetes.io'];
	if (isObject(k8s) && isObject(k8s.serviceaccount)) {
		const name = text(k8s.serviceaccount.name);
		if (name) return name;
	}
	const sub = text(claims.sub);
	const match = sub ? /^system:serviceaccount:[^:]+:(.+)$/.exec(sub) : null;
	return match ? match[1] : undefined;
}

function authorizationType(claims: JsonObject | undefined): string | undefined {
	const details = claims?.authorization_details;
	if (!Array.isArray(details)) return undefined;
	for (const entry of details) {
		if (isObject(entry)) {
			const type = text(entry.type);
			if (type) return type;
		}
	}
	return undefined;
}

/**
 * `turns` is the page's other turns. A refund's terms (amount, currency, account) travel in
 * the approval request, agent:hitl_required, which the agent sends in the turn that asks for
 * approval; the turn that completes the refund carries only the approval, agent:hitl_approved,
 * with the same auth_req_id. So when this turn has no terms of its own, they are taken from
 * the request its approval answers.
 */
export function turnAuditFacts(turn: Turn | undefined, requestId?: string, turns: Turn[] = []): TurnAuditFacts {
	const events = turn?.events ?? [];
	const seed = events.filter(isAuditSeed).pop();
	const credentials = events.filter(isCredential);
	const delegated = credentials.filter((c) => c.kind === 'delegated_token').pop();
	const saToken = credentials.filter((c) => c.kind === 'k8s_sa_token').pop();
	const userToken = credentials.filter((c) => c.kind === 'access_token' || c.kind === 'id_token').pop();

	// The audit key is the request ID in the turn's agent:audit_seed, else a refund tool's
	// result's, before any other ID the turn carried: a refund turn that also lists
	// transactions carries two IDs, and only the refund's is in the audit rows (Bear's
	// ruling on #68).
	const facts: TurnAuditFacts = {
		requestId: requestId ?? auditRequestId(events) ?? turn?.requestId,
		seed,
		vaultRole: seed?.vaultRole,
		dbRole: seed?.dbRole
	};

	const claims = delegated?.claims ?? seed?.claims ?? userToken?.claims;
	facts.sub = text(claims?.sub);
	facts.authorizationType = authorizationType(delegated?.claims) ?? authorizationType(seed?.claims);
	facts.serviceAccount = serviceAccountName(saToken?.claims);

	const exp = num(delegated?.claims?.exp);
	const iat = num(delegated?.claims?.iat);
	if (exp !== undefined && iat !== undefined && exp > iat) facts.delegatedTtlSeconds = Math.round(exp - iat);

	const approved = new Set(
		events.flatMap((event) => (event.type === 'agent:hitl_approved' ? [text(event.details?.auth_req_id)] : [])).filter(Boolean)
	);
	const answered = turns
		.filter((other) => other.id !== turn?.id)
		.flatMap((other) => other.events)
		.filter((event) => event.type === 'agent:hitl_required' && approved.has(text(event.details?.auth_req_id)));
	for (const event of [...answered, ...events]) {
		if (event.type === 'agent:hitl_approved' || event.type === 'agent:hitl_required') {
			const details = event.details;
			if (!details) continue;
			facts.amount = num(details.amount) ?? facts.amount;
			facts.currency = text(details.currency) ?? facts.currency;
			facts.accountId = text(details.account_id) ?? facts.accountId;
		}
	}

	const leases = seed?.leases ?? [];
	const writer = leases.find((lease) => text(lease.vault_path)?.endsWith('/uc3-refund-writer')) ?? leases[0];
	if (writer) {
		facts.lease = {
			vaultPath: text(writer.vault_path),
			leaseId: text(writer.lease_id),
			ttlSeconds: num(writer.ttl_seconds)
		};
	}

	const times = events.map((e) => ('ts' in e && typeof e.ts === 'number' ? e.ts : null)).filter((t): t is number => t !== null);
	const start = turn?.startedAt ?? (times.length > 0 ? Math.min(...times) : undefined);
	const end = times.length > 0 ? Math.max(...times) : undefined;
	if (start !== undefined && end !== undefined && end >= start) facts.durationMs = end - start;
	return facts;
}

/** 4.2 s · 38 s · 1 m 12 s */
export function formatDuration(ms: number | undefined): string {
	if (ms === undefined) return '';
	const seconds = ms / 1000;
	if (seconds < 10) return `${seconds.toFixed(1)} s`;
	if (seconds < 60) return `${Math.round(seconds)} s`;
	const minutes = Math.floor(seconds / 60);
	return `${minutes} m ${Math.round(seconds - minutes * 60)} s`;
}

/** $18.99 when the currency is a known ISO code, otherwise 18.99 XYZ; empty when unknown. */
export function formatAmount(amount: number | undefined, currency: string | undefined): string {
	if (amount === undefined) return '';
	if (currency) {
		try {
			return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(amount);
		} catch {
			return `${amount} ${currency}`;
		}
	}
	return String(amount);
}

/** 14:03:11 in the viewer's time zone, or — when unknown. */
export function formatClock(at: number | null): string {
	if (at === null) return '—';
	return new Intl.DateTimeFormat(undefined, {
		hour: '2-digit',
		minute: '2-digit',
		second: '2-digit',
		hourCycle: 'h23'
	}).format(at);
}
