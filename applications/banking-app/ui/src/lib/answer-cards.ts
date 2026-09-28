/**
 * answer-cards.ts — the card each tool call's result gets in a chat answer, read from that
 * turn's events ($lib/agent-events) and nothing else. It extends $lib/accounts-turn, whose
 * get_accounts card (with its footer rule) it reuses unchanged.
 *
 * The approved #65 boards draw every answer the same way: a chip per tool call, a card of
 * what the tool returned with the credential that read it in the card's footer, the Audit
 * Trace card, then the answer. A card is drawn for these tools, one per call that succeeded
 * with a result of the drawn shape, in the order the calls started:
 *
 *   get_accounts                  Use Case 2   "Your accounts" ($lib/accounts-turn)
 *   get_transactions              Use Case 2   "Your recent transactions": date, description,
 *                                              merchant, category, account id, amount
 *   list_transactions             Use Case 3   "Your recent transactions": #, date, description,
 *                                              merchant, account type, amount
 *   initiate_refund               Use Case 3   "Refund approval requested" (label/value rows)
 *   complete_refund               Use Case 3   "Refund complete" (label/value rows)
 *   check_refund_status           Use Case 3   "Refund status" (label/value rows)
 *   retrieve_from_knowledge_base  Use Case 1   "Sources"
 *   query_database                Use Case 1   "Database query": the SQL and the rows
 *
 * A call that failed, or a tool with no drawn card, keeps its chip and gets no card. Every row
 * the tool returned is shown; amounts are formatted with their minus sign as it came, and
 * account ids are shown as returned, never looked up.
 *
 * Footers name the credential the tool read with, from the stream only:
 *   - complete_refund: the agent:audit_seed's `leases` entry whose vault_path ends in
 *     /uc3-refund-writer (lease_id, ttl_seconds), with the seed's dbRole. The call's window
 *     also holds the owner check's read-only credential, so the window rule below would not
 *     single the writer out.
 *   - retrieve_from_knowledge_base: the one aws_sts_credentials event in the call's window,
 *     and the Vault role from the turn's agent:audit_seed.
 *   - every other tool: the one db_credentials event in the call's window. The database role
 *     is the last segment of that event's vaultPath; query_database also names the Vault role.
 * A call's window runs from its first tool_call event to its result. With no such event, or
 * more than one (calls that overlap), the value is left undefined and the card shows it as
 * "not in the stream" rather than guess. Nothing here reads a credential's label.
 */

import type { AgentCredentialEvent, AgentEvent, CredentialKind, JsonObject, JsonValue, ToolCallEvent } from '$lib/agent-events';
import { accountsCardsOf, formatAccountType, formatBalance, type AccountsCardView } from '$lib/accounts-turn';

/** The credential a card's footer names. Any part the stream did not carry is undefined. */
export interface CardCredential {
	/** The database role, or for the knowledge base the Vault role. */
	role?: string;
	vaultPath?: string;
	leaseId?: string;
	ttlSeconds?: number;
}

export interface TransactionRow {
	/** The date part of created_at, e.g. "2026-09-25". */
	date?: string;
	description?: string;
	merchant?: string;
	category?: string;
	accountId?: string;
	accountType?: string;
	/** The amount exactly as the tool returned it, e.g. "-88.30" or -88.3. */
	amount?: string;
}

export interface RefundFields {
	refundId?: string;
	transactionId?: string;
	accountId?: string;
	merchant?: string;
	amount?: string;
	currency?: string;
	approvedBy?: string;
	status?: string;
	createdAt?: string;
	requestId?: string;
	channel?: string;
	authReqId?: string;
}

export interface Source {
	document: string;
	score?: number;
}

export type AnswerCardView =
	| ({ kind: 'get_accounts' } & AccountsCardView)
	| { kind: 'get_transactions' | 'list_transactions'; key: string; rows: TransactionRow[]; credential?: CardCredential }
	| { kind: 'initiate_refund' | 'complete_refund' | 'check_refund_status'; key: string; refund: RefundFields; credential?: CardCredential }
	| { kind: 'retrieve_from_knowledge_base'; key: string; sources: Source[]; vaultRole?: string; credential?: CardCredential }
	| {
			kind: 'query_database';
			key: string;
			sql?: string;
			rowCount: number;
			columns: string[];
			/** One cell per column, in column order; undefined where a row lacks the column. */
			rows: (JsonValue | undefined)[][];
			vaultRole?: string;
			credential?: CardCredential;
	  };

// ---------------------------------------------------------------------------------- reading values

function isObject(value: JsonValue | undefined): value is JsonObject {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** A string or number as text; anything else (absent, null, an object) as undefined. */
function text(value: JsonValue | undefined): string | undefined {
	if (typeof value === 'string') return value;
	if (typeof value === 'number' && Number.isFinite(value)) return String(value);
	return undefined;
}

/** The last path segment: the role a Vault path such as database/creds/uc3-readonly issues for. */
const roleOf = (vaultPath: string | undefined) => vaultPath?.split('/').at(-1) || undefined;

// ---------------------------------------------------------------------------------- footers

/** Index of the first event of a tool call: where its window starts. */
function startOf(events: AgentEvent[], toolCallId: string): number {
	return events.findIndex((e) => e.type === 'tool_call' && e.toolCallId === toolCallId);
}

/** The one credential of `kind` in the call's window, or undefined when there is none or more than one. */
function windowCredential(events: AgentEvent[], start: number, resultIndex: number, kind: CredentialKind): AgentCredentialEvent | undefined {
	const found = events
		.slice(Math.max(start, 0), resultIndex)
		.filter((e): e is AgentCredentialEvent => e.type === 'agent:credential' && e.kind === kind);
	return found.length === 1 ? found[0] : undefined;
}

function dbCredential(events: AgentEvent[], start: number, resultIndex: number): CardCredential | undefined {
	const event = windowCredential(events, start, resultIndex, 'db_credentials');
	if (!event) return undefined;
	return { role: roleOf(event.vaultPath), vaultPath: event.vaultPath, leaseId: event.leaseId, ttlSeconds: event.ttlSeconds };
}

/**
 * complete_refund's write credential: the /uc3-refund-writer lease of the turn's audit seed. The
 * seed of this call is the last one before its result that carries such a lease; an agent that
 * sends the seed after the result is covered by the first one after it.
 */
function writerCredential(events: AgentEvent[], resultIndex: number): CardCredential | undefined {
	let before: CardCredential | undefined;
	let after: CardCredential | undefined;
	events.forEach((event, index) => {
		if (event.type !== 'agent:audit_seed' || index === resultIndex) return;
		const lease = (event.leases ?? []).find((l) => isObject(l) && text(l.vault_path)?.endsWith('/uc3-refund-writer'));
		if (!lease) return;
		const vaultPath = text(lease.vault_path);
		const ttl = lease.ttl_seconds;
		const credential: CardCredential = {
			role: event.dbRole || roleOf(vaultPath),
			vaultPath,
			leaseId: text(lease.lease_id),
			ttlSeconds: typeof ttl === 'number' && Number.isFinite(ttl) ? ttl : undefined
		};
		if (index < resultIndex) before = credential;
		else after ??= credential;
	});
	return before ?? after;
}

function vaultRoleOf(events: AgentEvent[]): string | undefined {
	for (const event of events) if (event.type === 'agent:audit_seed' && event.vaultRole) return event.vaultRole;
	return undefined;
}

// ---------------------------------------------------------------------------------- results

/** The date part of a timestamp ("2026-09-25T12:48:43.836Z" or "2026-09-25 12:48:43"). */
function datePart(value: string | undefined): string | undefined {
	return value && /^\d{4}-\d{2}-\d{2}/.test(value) ? value.slice(0, 10) : value;
}

function transactionRows(result: JsonValue | undefined): TransactionRow[] | null {
	if (!Array.isArray(result)) return null;
	const rows: TransactionRow[] = [];
	for (const item of result) {
		if (!isObject(item)) return null;
		rows.push({
			date: datePart(text(item.created_at)),
			description: text(item.description),
			merchant: text(item.merchant),
			category: text(item.category),
			accountId: text(item.account_id),
			accountType: text(item.account_type),
			amount: text(item.amount)
		});
	}
	return rows;
}

function refundFields(result: JsonValue | undefined): RefundFields | null {
	// A refund the agent could not find comes back as { error }: that is not a refund record.
	if (!isObject(result) || (result.error !== undefined && result.refund_id === undefined && result.auth_req_id === undefined)) return null;
	return {
		refundId: text(result.refund_id),
		transactionId: text(result.transaction_id),
		accountId: text(result.account_id),
		merchant: text(result.merchant),
		amount: text(result.amount),
		currency: text(result.currency),
		approvedBy: text(result.approved_by),
		status: text(result.status),
		createdAt: text(result.created_at),
		requestId: text(result.request_id),
		channel: text(result.channel),
		authReqId: text(result.auth_req_id)
	};
}

function sourceList(result: JsonValue | undefined): Source[] | null {
	if (!isObject(result) || !Array.isArray(result.sources)) return null;
	const sources: Source[] = [];
	for (const item of result.sources) {
		if (isObject(item) && typeof item.document === 'string') {
			sources.push({ document: item.document, score: typeof item.score === 'number' ? item.score : undefined });
		}
	}
	return sources.length > 0 ? sources : null;
}

/** The SQL a query_database call ran: the `query` argument of the call's first event that carries one. */
function sqlOf(events: AgentEvent[], toolCallId: string): string | undefined {
	for (const event of events) {
		if (event.type === 'tool_call' && event.toolCallId === toolCallId && isObject(event.args)) {
			const sql = text(event.args.query);
			if (sql !== undefined) return sql;
		}
	}
	return undefined;
}

function queryTable(result: JsonValue | undefined): { rowCount: number; columns: string[]; rows: (JsonValue | undefined)[][] } | null {
	if (!isObject(result) || !Array.isArray(result.rows)) return null;
	const records = result.rows.filter(isObject);
	const columns: string[] = [];
	for (const record of records) for (const column of Object.keys(record)) if (!columns.includes(column)) columns.push(column);
	const count = result.row_count;
	return {
		rowCount: typeof count === 'number' && Number.isFinite(count) ? count : records.length,
		columns,
		rows: records.map((record) => columns.map((column) => record[column]))
	};
}

// ---------------------------------------------------------------------------------- cards

/** Every card of the turn, in the order their calls started. See the module comment. */
export function answerCardsOf(events: AgentEvent[]): AnswerCardView[] {
	const cards: { start: number; card: AnswerCardView }[] = [];
	for (const card of accountsCardsOf(events)) cards.push({ start: startOf(events, card.key), card: { kind: 'get_accounts', ...card } });

	events.forEach((event, index) => {
		if (event.type !== 'tool_call' || event.status !== 'success') return;
		const call: ToolCallEvent = event;
		const key = call.toolCallId;
		const start = startOf(events, key);
		let card: AnswerCardView | null = null;
		switch (call.name) {
			case 'get_transactions':
			case 'list_transactions': {
				const rows = transactionRows(call.result);
				if (rows) card = { kind: call.name, key, rows, credential: dbCredential(events, start, index) };
				break;
			}
			case 'initiate_refund':
			case 'check_refund_status': {
				const refund = refundFields(call.result);
				if (refund) card = { kind: call.name, key, refund, credential: dbCredential(events, start, index) };
				break;
			}
			case 'complete_refund': {
				const refund = refundFields(call.result);
				if (refund) card = { kind: call.name, key, refund, credential: writerCredential(events, index) };
				break;
			}
			case 'retrieve_from_knowledge_base': {
				const sources = sourceList(call.result);
				const keys = windowCredential(events, start, index, 'aws_sts_credentials');
				if (sources) {
					card = {
						kind: call.name,
						key,
						sources,
						vaultRole: vaultRoleOf(events),
						credential: keys && { vaultPath: keys.vaultPath, leaseId: keys.leaseId, ttlSeconds: keys.ttlSeconds }
					};
				}
				break;
			}
			case 'query_database': {
				const table = queryTable(call.result);
				if (table) card = { kind: call.name, key, sql: sqlOf(events, key), ...table, vaultRole: vaultRoleOf(events), credential: dbCredential(events, start, index) };
				break;
			}
		}
		if (card) cards.push({ start, card });
	});

	return cards.sort((a, b) => a.start - b.start).map(({ card }) => card);
}

// ---------------------------------------------------------------------------------- layout

/** A value in a card: text, or undefined for one the stream did not carry ("not in the stream"). */
export type CardValue = string | undefined;

export interface CardColumn {
	label: string;
	/** Right-aligned, as the boards draw amounts and numbers. */
	right?: boolean;
}

export interface CardCell {
	value: CardValue;
	/** mono: IBM Plex Mono, left; num: IBM Plex Mono, right-aligned, never wrapped. */
	style?: 'mono' | 'num';
}

export interface CardRecordRow {
	label: string;
	value: CardValue;
}

/** Everything a tool-result card shows, ready to render. */
export interface CardLayout {
	title: string;
	subtitle: string;
	/** Shown after the subtitle as code, e.g. the SQL a query ran; `value` undefined when the stream did not carry it. */
	code?: { value: CardValue };
	tag: string;
	/** 'wait' is the amber tag of a refund waiting for approval; otherwise teal. */
	tone?: 'wait';
	/** A table of rows… */
	table?: { columns: CardColumn[]; rows: CardCell[][] };
	/** …or a single record as label/value rows. */
	record?: CardRecordRow[];
	/** The footer's two halves, each a run of text and values. */
	footer: [CardValue[], CardValue[]];
}

/** "$5.00 USD" from "5.00" (or 5) and "USD". */
function money(amount: string | undefined, currency?: string): CardValue {
	if (amount === undefined) return undefined;
	return currency ? `${formatBalance(amount)} ${currency}` : formatBalance(amount);
}

const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** Text for a query result cell: numbers and strings as they are, null as "null", anything else as JSON. */
function cellText(value: JsonValue | undefined): CardValue {
	if (value === undefined) return undefined;
	if (typeof value === 'string') return value;
	if (typeof value === 'number' || typeof value === 'boolean' || value === null) return String(value);
	return JSON.stringify(value);
}

/** "db role <role> · <path>" | "lease <lease> · <ttl>s TTL", with each missing part left undefined. */
function dbFooter(credential: CardCredential | undefined, roleLabel = 'db role'): [CardValue[], CardValue[]] {
	return [
		[`${roleLabel} `, credential?.role, ' · ', credential?.vaultPath],
		['lease ', credential?.leaseId, ' · ', ...ttl(credential?.ttlSeconds, 's TTL')]
	];
}

function ttl(seconds: number | undefined, unit: string): CardValue[] {
	return typeof seconds === 'number' ? [`${seconds}${unit}`] : ['TTL ', undefined];
}

/**
 * How a card is drawn: title, subtitle, tag, table or record, and footer. `owner` is the
 * signed-in person's display name, for the subtitles that name whose records they are.
 */
export function cardLayout(card: Exclude<AnswerCardView, { kind: 'get_accounts' }>, owner?: string): CardLayout {
	const forOwner = owner ? ` for ${owner}` : '';
	switch (card.kind) {
		case 'get_transactions':
		case 'list_transactions': {
			const numbered = card.kind === 'list_transactions';
			const columns: CardColumn[] = numbered
				? [{ label: '#' }, { label: 'Date' }, { label: 'Description' }, { label: 'Merchant' }, { label: 'Account' }, { label: 'Amount', right: true }]
				: [{ label: 'Date' }, { label: 'Description' }, { label: 'Merchant' }, { label: 'Category' }, { label: 'Account' }, { label: 'Amount', right: true }];
			const rows = card.rows.map((row, i): CardCell[] => {
				const shared: CardCell[] = [{ value: row.date }, { value: row.description }, { value: row.merchant }];
				const amount: CardCell = { value: row.amount === undefined ? undefined : formatBalance(row.amount), style: 'num' };
				return numbered
					? [{ value: String(i + 1), style: 'mono' }, ...shared, { value: row.accountType === undefined ? undefined : formatAccountType(row.accountType) }, amount]
					: [...shared, { value: row.category === undefined ? undefined : formatAccountType(row.category) }, { value: row.accountId, style: 'mono' }, amount];
			});
			return {
				title: 'Your recent transactions',
				subtitle: `${count(card.rows.length, 'transaction', 'transactions')}${forOwner}`,
				tag: 'Row-level security',
				table: { columns, rows },
				footer: dbFooter(card.credential)
			};
		}
		case 'initiate_refund': {
			const r = card.refund;
			return {
				title: 'Refund approval requested',
				subtitle: `Pushed to ${owner ? `${owner}’s` : 'your'} IBM Verify app · nothing is written until approved`,
				tag: 'Waiting for approval',
				tone: 'wait',
				record: [
					{ label: 'Transaction', value: r.transactionId },
					{ label: 'Account', value: r.accountId },
					{ label: 'Amount', value: money(r.amount, r.currency) },
					{ label: 'Approval channel', value: r.channel },
					{ label: 'auth_req_id', value: r.authReqId },
					{ label: 'Request ID', value: r.requestId },
					{ label: 'Status', value: r.status }
				],
				footer: dbFooter(card.credential)
			};
		}
		case 'complete_refund': {
			const r = card.refund;
			const amount = money(r.amount, r.currency);
			return {
				title: 'Refund complete',
				subtitle: [amount ? `${amount} refunded` : 'Refunded', r.approvedBy ? `approved by ${r.approvedBy} on IBM Verify` : undefined]
					.filter(Boolean)
					.join(' · '),
				tag: 'Delegated token',
				record: [
					{ label: 'Refund ID', value: r.refundId },
					{ label: 'Transaction', value: r.transactionId },
					{ label: 'Account', value: r.accountId },
					{ label: 'Merchant', value: r.merchant },
					{ label: 'Amount', value: amount },
					{ label: 'Approved by', value: r.approvedBy },
					{ label: 'Status', value: r.status },
					{ label: 'Written', value: r.createdAt },
					{ label: 'Request ID', value: r.requestId }
				],
				footer: dbFooter(card.credential)
			};
		}
		case 'check_refund_status': {
			const r = card.refund;
			return {
				title: 'Refund status',
				subtitle: `Refund${forOwner}`,
				tag: 'Row-level security',
				record: [
					{ label: 'Refund ID', value: r.refundId },
					{ label: 'Transaction', value: r.transactionId },
					{ label: 'Account', value: r.accountId },
					{ label: 'Amount', value: money(r.amount, r.currency) },
					{ label: 'Approved by', value: r.approvedBy },
					{ label: 'Status', value: r.status },
					{ label: 'Written', value: r.createdAt },
					{ label: 'Request ID', value: r.requestId }
				],
				footer: dbFooter(card.credential)
			};
		}
		case 'retrieve_from_knowledge_base':
			return {
				title: 'Sources',
				subtitle: 'Retrieved from the Bedrock Knowledge Base',
				tag: 'Just-in-time access',
				table: {
					columns: [{ label: 'Document' }, { label: 'Relevance', right: true }],
					rows: card.sources.map((source) => [
						{ value: source.document, style: 'mono' },
						{ value: typeof source.score === 'number' ? source.score.toFixed(2) : undefined, style: 'num' }
					])
				},
				footer: [
					['vault role ', card.vaultRole, ' · ', card.credential?.vaultPath],
					['STS credentials · ', ...ttl(card.credential?.ttlSeconds, 's')]
				]
			};
		case 'query_database': {
			// A column is right-aligned when every value it holds is a number, as the board draws a count.
			const numeric = card.columns.map((_, c) => card.rows.length > 0 && card.rows.every((row) => typeof row[c] === 'number'));
			return {
				title: 'Database query',
				subtitle: count(card.rowCount, 'row', 'rows'),
				code: { value: card.sql },
				tag: 'Just-in-time access',
				table:
					card.columns.length > 0
						? {
								columns: card.columns.map((label, c) => ({ label, right: numeric[c] })),
								rows: card.rows.map((row) => row.map((value, c): CardCell => ({ value: cellText(value), style: numeric[c] ? 'num' : 'mono' })))
							}
						: undefined,
				footer: [
					['vault role ', card.vaultRole, ' · ', card.credential?.vaultPath],
					['lease ', card.credential?.leaseId, ' · ', ...ttl(card.credential?.ttlSeconds, 's TTL')]
				]
			};
		}
	}
}
