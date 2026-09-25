/**
 * accounts-turn.ts — what the banking chat shows for a turn in which the agent called
 * get_accounts: one chip per tool call, and a "Your accounts" card for each call that
 * returned rows, read from that turn's events ($lib/agent-events) and nothing else.
 *
 * Only a turn with a get_accounts call gets this view; every other banking turn keeps the
 * legacy layout (Bear, 2026-09-25, on #65).
 *
 * The card's footer names the database credential the MCP server read the rows with: the
 * db_credentials event sent between the call's start and its result. Tools can run at the
 * same time, so that window can hold another call's credential too. agent:credential carries
 * no toolCallId, so the one for this call is then the one whose label begins with the text
 * the agent writes for it (banking-app/agent/app/activity.py, report_credential_metadata:
 * "Database credential Vault issued for <tool>"). With none, or with more than one left,
 * the footer says "not observed" rather than guess.
 */

import type { AgentCredentialEvent, AgentEvent, JsonValue, ToolCallEvent, ToolCallStatus } from '$lib/agent-events';

/** The Use Case 2 tool whose result lists the member's accounts. */
export const ACCOUNTS_TOOL = 'get_accounts';

/** How the banking agent labels the database credential it was issued for a tool. */
const credentialLabelFor = (tool: string) => `Database credential Vault issued for ${tool}`;

export interface ToolCallView {
	id: string;
	name: string;
	status: ToolCallStatus;
	/** From the call's start to its result, in milliseconds. Absent while it runs. */
	durationMs?: number;
}

export interface AccountRow {
	accountNumber: string;
	accountType: string;
	/** The balance exactly as Postgres returned it, e.g. "4250.00". */
	balance: string;
}

export interface AccountsCardView {
	/** The get_accounts call the card belongs to. */
	key: string;
	accounts: AccountRow[];
	/** The database credential the rows were read with, when the turn's events identify it. */
	credential?: Pick<AgentCredentialEvent, 'vaultPath' | 'leaseId' | 'ttlSeconds'>;
}

/** True when the turn holds a get_accounts call, in any state. */
export function hasAccountsCall(events: AgentEvent[]): boolean {
	return events.some((e) => e.type === 'tool_call' && e.name === ACCOUNTS_TOOL);
}

/**
 * One view per tool call, in the order the calls started, at their latest status. The
 * duration is the one the agent reported; without it, the time between the call's first
 * event and its result.
 */
export function toolCallsOf(events: AgentEvent[]): ToolCallView[] {
	const byId = new Map<string, ToolCallView & { startedTs?: number }>();
	for (const event of events) {
		if (event.type !== 'tool_call') continue;
		const known = byId.get(event.toolCallId);
		const startedTs = known?.startedTs ?? event.ts;
		let durationMs = event.durationMs ?? known?.durationMs;
		if (durationMs === undefined && event.status !== 'in_progress' && startedTs !== undefined && event.ts !== undefined) {
			durationMs = Math.max(0, event.ts - startedTs);
		}
		byId.set(event.toolCallId, { id: event.toolCallId, name: event.name, status: event.status, durationMs, startedTs });
	}
	return [...byId.values()].map(({ id, name, status, durationMs }) => ({ id, name, status, durationMs }));
}

function isObject(value: JsonValue | undefined): value is { [key: string]: JsonValue } {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** The rows of a get_accounts result, or null when the result is not a list of accounts. */
function accountRows(result: JsonValue | undefined): AccountRow[] | null {
	if (!Array.isArray(result)) return null;
	const rows: AccountRow[] = [];
	for (const item of result) {
		if (!isObject(item) || typeof item.account_number !== 'string') return null;
		rows.push({
			accountNumber: item.account_number,
			accountType: typeof item.account_type === 'string' ? item.account_type : '',
			balance: typeof item.balance === 'string' || typeof item.balance === 'number' ? String(item.balance) : ''
		});
	}
	return rows;
}

/** The database credential of one tool call, found as the module comment describes. */
function credentialOf(events: AgentEvent[], call: ToolCallEvent, resultIndex: number): AccountsCardView['credential'] {
	const start = events.findIndex((e) => e.type === 'tool_call' && e.toolCallId === call.toolCallId);
	const inWindow = events
		.slice(Math.max(start, 0), resultIndex)
		.filter((e): e is AgentCredentialEvent => e.type === 'agent:credential' && e.kind === 'db_credentials');
	const mine = inWindow.length === 1 ? inWindow : inWindow.filter((e) => e.label.startsWith(credentialLabelFor(call.name)));
	if (mine.length !== 1) return undefined;
	const { vaultPath, leaseId, ttlSeconds } = mine[0];
	return { vaultPath, leaseId, ttlSeconds };
}

/** A "Your accounts" card for each get_accounts call that succeeded with a list of accounts. */
export function accountsCardsOf(events: AgentEvent[]): AccountsCardView[] {
	const cards: AccountsCardView[] = [];
	events.forEach((event, index) => {
		if (event.type !== 'tool_call' || event.name !== ACCOUNTS_TOOL || event.status !== 'success') return;
		const accounts = accountRows(event.result);
		if (!accounts) return;
		cards.push({ key: event.toolCallId, accounts, credential: credentialOf(events, event, index) });
	});
	return cards;
}

/** "0.4s", as the board writes a call's duration; "<0.1s" below a tenth of a second. */
export function formatDuration(ms: number): string {
	return ms < 100 ? '<0.1s' : `${(ms / 1000).toFixed(1)}s`;
}

const usd = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** "$4,250.00" from "4250.00". A balance that is not a number is shown as it came. */
export function formatBalance(balance: string): string {
	const value = Number(balance);
	return balance.trim() !== '' && Number.isFinite(value) ? usd.format(value) : balance;
}

/** "Checking" from "checking". */
export function formatAccountType(type: string): string {
	return type ? type.charAt(0).toUpperCase() + type.slice(1) : type;
}
