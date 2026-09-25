/**
 * security-flow.ts — turns one chat turn's events into the five stops of the Security Flow.
 *
 *     Request → Agent → Authorization → Secure execution → Result
 *
 * buildFlow() is pure: the same events always give the same flow. It reads only the events
 * the page actually received (the contract in ./agent-events) plus what the page itself did
 * (the question it sent, whether the stream has ended). Nothing is timed, scripted or
 * assumed. Every stop and every signal carries one of three statuses:
 *
 *   observed      the stream reported the event that proves it;
 *   pending       not reported yet, and it still can be: the turn is running, or the flow
 *                 is waiting for a person (an approval that is still open);
 *   not observed  the turn has ended and the stream never reported it.
 *
 * Which event proves what
 * -----------------------
 * Signals are matched on structured fields first — the event type, a credential's `kind`,
 * `issuer` and `vaultPath`, a tool call's `name` and `status`, the HITL event types. Never on
 * whether a credential's `value`, `fields` or `claims` is present: the UI server's activity
 * filter decides which of those reach the browser, and the flow must read the same whichever
 * it passes. Where the only evidence of a fact is an Agent Log line, the line's opening words
 * are matched, and where two credentials share a `vaultPath` (Use Case 1's model keys and
 * knowledge-base keys), the credential label's opening words tell them apart; each of those is
 * a named constant below with the agent source line that writes it. So a filter may remove
 * values, but must pass a credential's `label` and a narration's `text` through unchanged.
 * Each signal lists the events that prove it; remove them from a turn and the signal turns
 * back to not observed.
 *
 * Arrival order
 * -------------
 * Evidence is listed in the order events arrived, never sorted by `ts`: the refund agent
 * holds some credentials back and stamps `ts` when it releases them. `ts` is used only for
 * the "+1.2s" label, counted from the agent's first event so that every time is on the pod's
 * clock; the page's own send time is on the browser's clock and never mixed in.
 */

import type { AgentCredentialEvent, AgentEvent, JsonObject, JsonValue } from './agent-events';
import { auditRequestId } from './audit-trace';

export type UseCase = 1 | 2 | 3;

export type FlowStatus = 'observed' | 'not observed' | 'pending';

/** ok: nothing went wrong · waiting: waiting for a person · failed: refused, denied or errored. */
export type FlowTone = 'ok' | 'waiting' | 'failed';

export const STOP_IDS = ['request', 'agent', 'authorization', 'execution', 'result'] as const;
export type StopId = (typeof STOP_IDS)[number];

export const STOP_LABELS: Record<StopId, string> = {
	request: 'Request',
	agent: 'Agent',
	authorization: 'Authorization',
	execution: 'Secure execution',
	result: 'Result'
};

/** The status line shown for a signal that never arrived. */
export const NOT_OBSERVED_TEXT = 'not observed in this flow';

/** What the focus card and the "What's happening" card say about one stop. */
export interface StopStory {
	/** Focus card eyebrow, e.g. "Complete", "In progress". */
	eyebrow: string;
	/** Focus card title, e.g. "Waiting for your approval". */
	title: string;
	/** Focus card line under the title. */
	line: string;
	/** Focus card status chip, e.g. "Awaiting approval". */
	chip: string;
	/** "What's happening" heading. */
	heading: string;
	/** "What's happening" body. */
	body: string;
	/** Optional small print under the body. */
	note?: string;
}

export interface Stop {
	id: StopId;
	label: string;
	status: FlowStatus;
	tone: FlowTone;
	story: StopStory;
	/** Protocol and standard names this stop's observed signals carry, e.g. "CIBA". */
	chips: string[];
	/** Identifiers to show under the chips, e.g. auth_req_id and request. */
	ids: { label: string; value: string }[];
}

export interface Signal {
	id: string;
	stop: StopId;
	label: string;
	status: FlowStatus;
	tone: FlowTone;
	/** Shown after the status, e.g. "about 60 s". */
	note?: string;
	/** Indexes into `evidence` of the rows that prove this signal. */
	evidence: number[];
}

export interface EvidenceRow {
	index: number;
	/** "+1.2s" after the agent's first event, or "" for a row with no agent time (the page's own). */
	t: string;
	/** Where the row came from: the event type, or local:* for what the page itself did. */
	src: string;
	/** Normalized kind, e.g. "vault.cred_mint". */
	kind: string;
	/** e.g. success, issued, waiting, denied, error. */
	status: string;
	/** Plain-English line. */
	line: string;
	/** The stop this row belongs to. */
	stop: StopId;
	/** The event exactly as received (or what the page did), shown in full on request. */
	raw: JsonValue;
}

export interface Flow {
	useCase: UseCase;
	/** "Ask", "Banking" or "Refund": the bold word in the request box. */
	requestLabel: string;
	question?: string;
	requestId?: string;
	/** The turn has ended. */
	done: boolean;
	/** An approval is open: the flow waits at Authorization, even after the turn ends. */
	waiting: boolean;
	/** The stop the focus card describes. */
	focus: StopId;
	stops: Stop[];
	/** Every signal of the turn. The stops' statuses are derived from these. */
	signals: Signal[];
	/**
	 * The rows the Technical view lists under "Technical signals". For a refund turn these are
	 * the approved mockup's rows, in its order (REFUND_TECHNICAL_ROWS); every other turn lists
	 * all its signals.
	 */
	technical: Signal[];
	evidence: EvidenceRow[];
}

/** What the page itself knows about the turn, beyond its events. All optional. */
export interface FlowContext {
	/** The question the page sent. */
	question?: string;
	/**
	 * When the page sent it, in milliseconds since the Unix epoch on the browser's clock. Kept in
	 * the question's evidence row; not used for the "+1.2s" times, which are on the pod's clock.
	 */
	startedAt?: number;
	/**
	 * The stream has ended. Every agent ends a turn with agent:done (the refund agent at
	 * applications/uc3-agent/app/main.py:258 and :265), which ends the flow on its own; this
	 * covers a stream from before that, which ended only on the legacy `end` frame.
	 */
	done?: boolean;
	/**
	 * The answer the page received. The refund agent sends it as agent:text_delta
	 * (applications/uc3-agent/app/main.py:257); a stream from before that carried it only as the
	 * legacy `delta` frame, and for such a stream this becomes the answer's evidence row.
	 */
	answer?: string;
}

// ---------------------------------------------------------------------------
// Agent Log lines matched by their opening words — the only evidence of these facts.
// Source paths are relative to the repository root.
// ---------------------------------------------------------------------------

/** infrastructure/modules/uc1_agent/agent/app/agent.py:137 and :602 */
const UC1_NO_USER = 'No user is signed in.';
/** infrastructure/modules/uc1_agent/agent/app/agent.py:165 */
const UC1_KB_KEYS_LABEL = 'Short-lived AWS keys Vault issued for reading the knowledge base';
/** infrastructure/modules/uc1_agent/agent/app/agent.py:200 and :524 */
const UC1_MODEL_KEYS_LABEL = 'Short-lived AWS keys Vault issued for calling the model';
/** infrastructure/modules/uc1_agent/agent/app/agent.py:110 — the login was made on an earlier turn */
const UC1_SA_REUSED = 'not presented again';

/** applications/banking-app/agent/app/activity.py:470 (followed at :471 by "... as X-Vault-Token") */
const UC2_X_VAULT_TOKEN = 'The MCP server reports it read';
/** applications/banking-app/agent/app/activity.py:525 */
const UC2_REVOKED = 'The MCP server reports Vault revoked the ';
/** applications/banking-app/agent/app/activity.py:528 */
const UC2_REVOKE_FAILED = 'The MCP server reports its revoke of the ';
/** applications/banking-app/agent/app/activity.py:568 */
const UC2_LOOKUP_SELF = "The MCP server reports Vault's lookup-self for the caller's token during ";
/** applications/banking-app/agent/app/activity.py:554 — present only when the ceiling was read */
const UC2_CEILING_READ = " The agent's ceiling, read from ";
/** applications/banking-app/agent/app/activity.py:727 and :764 — the MCP server's own login */
const UC2_MCP_OWN = "The MCP server's own";

/** applications/uc3-agent/app/agent.py:171 */
const UC3_OWNER_OK = 'Account owner check passed:';
/** applications/uc3-agent/app/agent.py:164 */
const UC3_OWNER_REFUSED = 'Account owner check refused:';
/** applications/uc3-agent/app/agent.py:1050, :1065, :1077 and :1276 */
const UC3_REFUSED = 'Refused:';
/**
 * applications/uc3-agent/app/agent.py:216 (the refund terms checked before any approval is
 * requested) and :1227-1233 (the refundable amount re-checked inside the write)
 */
const UC3_TERMS_REFUSED = 'Refund refused:';
/** applications/uc3-agent/app/agent.py:920 */
const UC3_CIBA_SENT = 'Backchannel sign-in request (CIBA) sent';
/** applications/uc3-agent/app/agent.py:1108 */
const UC3_APPROVAL_POLL = "Checking IBM Verify Identity Access for the user's approval";
/** applications/uc3-agent/app/agent.py:748, narrated at :1118 */
const UC3_TOKEN_EXCHANGED = 'Token exchanged (RFC 8693)';
/** applications/uc3-agent/app/agent.py:1140 */
const UC3_WRITER_ISSUED = 'Vault issued a uc3-refund-writer database credential';
/** applications/uc3-agent/app/agent.py:1283 */
const UC3_REFUND_WRITTEN = 'Refund written: INSERT into banking.refunds';
/** applications/uc3-agent/app/agent.py:1349 */
const UC3_ANCHOR_OK = 'Audit anchor written to CloudWatch Logs';
/** applications/uc3-agent/app/agent.py:1358 */
const UC3_ANCHOR_FAILED = 'The audit anchor could not be written to CloudWatch Logs';
/** applications/uc3-agent/app/vault_client.py:221, the writer credential's vaultPath (sent at :243) */
const UC3_WRITER_PATH = 'database/creds/uc3-refund-writer';

const BEDROCK_KEYS_PATH = 'aws/sts/bedrock-reader';

// ---------------------------------------------------------------------------
// Reading the events
// ---------------------------------------------------------------------------

interface Seen {
	/** Arrival position in the turn's event list. */
	at: number;
	event: AgentEvent;
}

interface ToolRun {
	name: string;
	start?: Seen;
	end?: Seen;
}

class Facts {
	readonly list: Seen[];
	readonly tools: ToolRun[] = [];
	readonly requestId?: string;

	constructor(
		readonly useCase: UseCase,
		events: readonly AgentEvent[],
		readonly done: boolean,
		readonly context: FlowContext
	) {
		this.list = events.map((event, at) => ({ at, event }));
		const byId = new Map<string, ToolRun>();
		for (const seen of this.list) {
			const e = seen.event;
			if (e.type !== 'tool_call') continue;
			let run = byId.get(e.toolCallId);
			if (!run) {
				run = { name: e.name };
				byId.set(e.toolCallId, run);
				this.tools.push(run);
			}
			if (e.status === 'in_progress') run.start ??= seen;
			else run.end = seen;
		}
		// The ID the audit trail files this turn under, by the Audit Trace card's own rule.
		this.requestId = auditRequestId(events);
	}

	of<T extends AgentEvent['type']>(type: T): (Seen & { event: Extract<AgentEvent, { type: T }> })[] {
		return this.list.filter((s) => s.event.type === type) as (Seen & { event: Extract<AgentEvent, { type: T }> })[];
	}

	creds(kind: AgentCredentialEvent['kind'], test: (e: AgentCredentialEvent) => boolean = () => true): Seen[] {
		return this.of('agent:credential').filter((s) => s.event.kind === kind && test(s.event));
	}

	/** Agent Log lines that start with `prefix` (and, optionally, pass `test`). */
	lines(prefix: string, test: (text: string) => boolean = () => true): Seen[] {
		return this.of('agent:narration').filter((s) => s.event.text.startsWith(prefix) && test(s.event.text));
	}

	ran(name: string): boolean {
		return this.tools.some((t) => t.name === name && (t.start || t.end));
	}

	toolEnds(name: string, status: 'success' | 'error'): Seen[] {
		return this.of('tool_call').filter((s) => s.event.name === name && s.event.status === status);
	}
}

// ---------------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------------

interface SignalSpec {
	id: string;
	stop: StopId;
	label: string;
	/** Events that prove the signal. Observed when non-empty. */
	seen: Seen[];
	/** Events that prove it went wrong. Observed, tone failed. */
	failed?: Seen[];
	/** Label shown instead when it went wrong. */
	failedLabel?: string;
	/** Still waiting for a person: pending even once the turn has ended. */
	waiting?: boolean;
	/** Counts toward the stop's status. */
	required?: boolean;
	/** Status note, e.g. "about 60 s". */
	note?: string;
	chips?: string[];
}

interface BuiltSignal extends Signal {
	required: boolean;
	chips: string[];
	seenAt: number[];
}

function toSignal(spec: SignalSpec, done: boolean): BuiltSignal {
	const failed = spec.failed ?? [];
	let status: FlowStatus;
	let tone: FlowTone = 'ok';
	let proof: Seen[] = spec.seen;
	let label = spec.label;
	if (failed.length > 0) {
		status = 'observed';
		tone = 'failed';
		proof = failed;
		label = spec.failedLabel ?? spec.label;
	} else if (spec.seen.length > 0) {
		status = 'observed';
	} else if (spec.waiting) {
		status = 'pending';
		tone = 'waiting';
	} else {
		status = done ? 'not observed' : 'pending';
	}
	return {
		id: spec.id,
		stop: spec.stop,
		label,
		status,
		tone,
		note: status === 'observed' || spec.waiting ? spec.note : undefined,
		evidence: [],
		seenAt: proof.map((s) => s.at),
		required: spec.required ?? false,
		chips: status === 'observed' && tone === 'ok' ? (spec.chips ?? []) : []
	};
}

function toolSignals(f: Facts, stop: StopId, required: boolean): SignalSpec[] {
	return f.tools
		.filter((t) => t.start || t.end)
		.map((t) => ({
			id: `tool:${t.name}`,
			stop,
			label: `${t.name} returned`,
			failedLabel: `${t.name} failed`,
			seen: t.end && t.end.event.type === 'tool_call' && t.end.event.status === 'success' ? [t.end] : [],
			failed: t.end && t.end.event.type === 'tool_call' && t.end.event.status === 'error' ? [t.end] : [],
			required
		}));
}

function choiceSignals(f: Facts): SignalSpec[] {
	const names = [...new Set(f.tools.filter((t) => t.start).map((t) => t.name))];
	return names.map((name) => ({
		id: `choose:${name}`,
		stop: 'agent',
		label: `Agent chose ${name}`,
		seen: f.tools.filter((t) => t.name === name && t.start).map((t) => t.start as Seen),
		required: true
	}));
}

function answerSignal(f: Facts): SignalSpec {
	return {
		id: 'answer',
		stop: 'result',
		label: 'Answer written',
		seen: f.of('agent:text_delta'),
		failed: f.of('agent:error'),
		failedLabel: 'The turn failed',
		required: true
	};
}

function useCase1Signals(f: Facts): SignalSpec[] {
	const dbRan = f.ran('query_database');
	const kbRan = f.ran('retrieve_from_knowledge_base');
	const db = f.creds('db_credentials', (e) => e.issuer === 'Vault');
	const sa = f.creds('k8s_sa_token', (e) => e.issuer === 'Kubernetes');
	const saReused = sa.some((s) => s.event.type === 'agent:credential' && s.event.label.includes(UC1_SA_REUSED));
	const specs: SignalSpec[] = [
		{
			id: 'request-id',
			stop: 'request',
			label: 'Request ID assigned by the agent',
			seen: f.list.filter((s) => s.event.requestId === f.requestId).slice(0, 1),
			required: true,
			chips: ['request_id']
		},
		{ id: 'no-user', stop: 'request', label: 'No user signed in: the agent acts as itself', seen: f.lines(UC1_NO_USER) },
		{ id: 'thinking', stop: 'agent', label: 'Agent started reasoning', seen: f.of('agent:thinking').slice(0, 1), required: true },
		...choiceSignals(f),
		{
			id: 'model-keys',
			stop: 'agent',
			label: `Model calls signed with short-lived AWS keys from Vault (${BEDROCK_KEYS_PATH})`,
			seen: f.creds('aws_sts_credentials', (e) => e.label.startsWith(UC1_MODEL_KEYS_LABEL)),
			chips: ['AWS STS']
		},
		{
			id: 'sa-token',
			stop: 'authorization',
			label: saReused
				? "Vault login reused, made earlier with the agent's Kubernetes service-account token"
				: 'Kubernetes service-account token presented to Vault',
			seen: sa,
			chips: ['Kubernetes auth']
		},
		{
			id: 'vault-token',
			stop: 'authorization',
			label: "Vault token from the agent's own Kubernetes login",
			seen: f.creds('vault_token', (e) => e.issuer === 'Vault'),
			required: true
		}
	];
	if (dbRan) {
		specs.push({
			id: 'db-cred',
			stop: 'execution',
			label: 'Vault issued a short-lived database credential (database/creds/uc1-readonly)',
			seen: db,
			required: true,
			chips: ['Vault database secrets']
		});
	}
	if (kbRan) {
		specs.push({
			id: 'kb-keys',
			stop: 'execution',
			label: `Vault issued AWS keys for the knowledge base (${BEDROCK_KEYS_PATH})`,
			seen: f.creds('aws_sts_credentials', (e) => e.label.startsWith(UC1_KB_KEYS_LABEL)),
			required: true,
			chips: ['AWS STS']
		});
	}
	specs.push(...toolSignals(f, 'execution', true));
	if (dbRan) {
		// The Use Case 1 agent never revokes its lease and reports no revoke.
		specs.push({ id: 'revoked', stop: 'execution', label: 'Credential revoked', seen: [] });
	}
	specs.push(answerSignal(f), {
		id: 'audit-seed',
		stop: 'result',
		label: 'Request ID and lease IDs handed to the audit trail',
		seen: f.of('agent:audit_seed'),
		chips: ['request_id']
	});
	return specs;
}

function useCase2Signals(f: Facts): SignalSpec[] {
	const agentOwn = (e: AgentCredentialEvent) => !e.label.startsWith(UC2_MCP_OWN);
	const lookup = f.lines(UC2_LOOKUP_SELF);
	const specs: SignalSpec[] = [
		{
			id: 'request-id',
			stop: 'request',
			label: 'Request ID assigned by the agent',
			seen: f.list.filter((s) => s.event.requestId === f.requestId).slice(0, 1),
			required: true,
			chips: ['request_id']
		},
		{
			id: 'access-token',
			stop: 'request',
			label: "Signed-in user's access token carried with the request",
			seen: f.creds('access_token', (e) => e.issuer === 'IBM Verify Identity Access'),
			chips: ['OAuth access token']
		},
		{ id: 'thinking', stop: 'agent', label: 'Agent started reasoning', seen: f.of('agent:thinking').slice(0, 1), required: true },
		...choiceSignals(f),
		{
			id: 'model-keys',
			stop: 'agent',
			label: `Model calls signed with AWS keys Vault issued to the agent (${BEDROCK_KEYS_PATH})`,
			seen: f.creds('aws_sts_credentials', (e) => e.vaultPath === BEDROCK_KEYS_PATH),
			chips: ['AWS STS']
		},
		{
			id: 'agent-login',
			stop: 'agent',
			label: "Agent's own Vault token from its Kubernetes login",
			seen: f.creds('vault_token', (e) => e.issuer === 'Vault' && agentOwn(e))
		}
	];
	if (f.tools.length > 0) {
		specs.push(
			{
				id: 'x-vault-token',
				stop: 'authorization',
				label: "User's token presented to Vault as X-Vault-Token (no Vault login)",
				seen: f.lines(UC2_X_VAULT_TOKEN, (t) => t.includes('X-Vault-Token')),
				required: true,
				chips: ['X-Vault-Token']
			},
			{
				id: 'policies',
				stop: 'authorization',
				label: "Caller's Vault policies listed (lookup-self)",
				seen: lookup
			},
			{
				id: 'ceiling',
				stop: 'authorization',
				label: "Agent's ceiling read from the Vault Agent Registry",
				seen: lookup.filter((s) => s.event.type === 'agent:narration' && s.event.text.includes(UC2_CEILING_READ)),
				chips: ['Agent Registry']
			},
			{
				id: 'db-cred',
				stop: 'execution',
				label: 'Vault issued a per-user database credential',
				seen: f.creds('db_credentials', (e) => e.issuer === 'Vault'),
				required: true,
				chips: ['Vault database secrets']
			},
			...toolSignals(f, 'execution', true),
			{
				id: 'revoked',
				stop: 'execution',
				label: 'Credential revoked before the MCP server replied',
				failedLabel: 'Credential revoke failed',
				seen: f.lines(UC2_REVOKED),
				failed: f.lines(UC2_REVOKE_FAILED, (t) => t.includes('FAILED')),
				chips: ['Lease revoke']
			}
		);
	}
	specs.push(answerSignal(f), {
		id: 'audit-seed',
		stop: 'result',
		label: 'Request ID and lease IDs handed to the audit trail',
		seen: f.of('agent:audit_seed'),
		chips: ['request_id']
	});
	return specs;
}

/**
 * Which half of the refund this turn ran, read from every event that only a refund turn sends,
 * so the flow does not hinge on one tool_call frame.
 */
function refundPhase(f: Facts): { initiate: boolean; complete: boolean } {
	const initiate = f.ran('initiate_refund') || f.of('agent:hitl_required').length > 0 || f.lines(UC3_CIBA_SENT).length > 0;
	const complete =
		f.ran('complete_refund') ||
		f.of('agent:hitl_approved').length + f.of('agent:hitl_denied').length + f.of('agent:hitl_timeout').length > 0 ||
		f.lines(UC3_APPROVAL_POLL).length > 0 ||
		f.lines(UC3_TOKEN_EXCHANGED).length > 0 ||
		f.creds('ciba_token').length + f.creds('delegated_token').length > 0 ||
		f.creds('db_credentials', (e) => e.vaultPath === UC3_WRITER_PATH).length > 0 ||
		f.lines(UC3_REFUND_WRITTEN).length > 0;
	return { initiate, complete };
}

function useCase3Signals(f: Facts): SignalSpec[] {
	const { initiate, complete } = refundPhase(f);
	const refundTurn = initiate || complete;
	const required = f.of('agent:hitl_required');
	const approved = f.of('agent:hitl_approved');
	const denied = f.of('agent:hitl_denied');
	const timedOut = f.of('agent:hitl_timeout');
	const open = required.length > 0 && approved.length + denied.length + timedOut.length === 0;
	const refused = [...f.lines(UC3_OWNER_REFUSED), ...f.lines(UC3_REFUSED), ...f.lines(UC3_TERMS_REFUSED)];

	const specs: SignalSpec[] = [
		{
			id: 'id-token',
			stop: 'request',
			label: "Signed-in user's id_token verified by the refund agent",
			seen: f.creds('id_token', (e) => e.issuer === 'IBM Verify Identity Access'),
			required: true
		},
		...choiceSignals(f),
		{
			id: 'model-keys',
			stop: 'agent',
			label: `Model calls signed with AWS keys Vault issued to the agent (${BEDROCK_KEYS_PATH})`,
			seen: f.creds('aws_sts_credentials', (e) => e.vaultPath === BEDROCK_KEYS_PATH)
		},
		{
			id: 'agent-login',
			stop: 'agent',
			label: "Agent's own Vault token from its Kubernetes login",
			seen: f.creds('vault_token', (e) => e.issuer === 'Vault')
		}
	];

	// The turn's requestId is the refund's only once a refund tool bound it: initiate_refund
	// does so first thing (applications/uc3-agent/app/agent.py:871), complete_refund only after
	// its three checks pass (:1083). A refusal before that carries the turn's own id instead
	// (applications/uc3-agent/app/activity.py:213), so a completion needs a step that runs after
	// the bind: the owner check, the approval poll, or the approval's outcome.
	const refundIdBound =
		initiate ||
		[...f.lines(UC3_OWNER_OK), ...f.lines(UC3_OWNER_REFUSED), ...f.lines(UC3_APPROVAL_POLL), ...approved, ...denied, ...timedOut].length > 0;
	if (refundTurn) {
		specs.push(
			{
				id: 'request-id',
				stop: 'request',
				label: 'Request ID bound to the refund',
				seen: refundIdBound ? f.list.filter((s) => s.event.requestId === f.requestId).slice(0, 1) : [],
				chips: ['request_id']
			},
			{
				id: 'owner-check',
				stop: 'authorization',
				label: 'Account ownership checked',
				failedLabel: 'Refused',
				seen: f.lines(UC3_OWNER_OK),
				failed: refused,
				required: true
			}
		);
	}
	if (initiate) {
		specs.push({
			id: 'approval-requested',
			stop: 'authorization',
			label: 'Approval requested on the phone (CIBA)',
			seen: required,
			required: true,
			chips: ['CIBA', 'RAR · RFC 9396']
		});
	}
	if (refundTurn) {
		specs.push({
			id: 'approval',
			stop: 'authorization',
			label: 'Approval received',
			failedLabel: denied.length > 0 ? 'Approval denied' : 'Approval timed out',
			seen: approved,
			failed: [...denied, ...timedOut],
			waiting: open,
			required: complete,
			chips: ['CIBA']
		});
	}
	if (complete) {
		const delegated = f.creds('delegated_token', (e) => e.issuer === 'IBM Verify Identity Access');
		// RAR is shown when the delegated token's claims carry authorization_details, or when the
		// agent's exchange line lists them (applications/uc3-agent/app/agent.py:742-744), so the
		// chip survives a filter that drops a credential's claims.
		const rar =
			delegated.some((s) => {
				const claims = s.event.type === 'agent:credential' ? s.event.claims : undefined;
				return Array.isArray(claims?.authorization_details);
			}) || f.lines(UC3_TOKEN_EXCHANGED, (t) => t.includes(' authorization_details ')).length > 0;
		specs.push(
			{
				id: 'delegated-token',
				stop: 'authorization',
				label: 'Token exchanged for delegated token',
				seen: delegated,
				required: true,
				chips: rar ? ['RFC 8693', 'RAR · RFC 9396'] : ['RFC 8693']
			},
			{
				id: 'writer-cred',
				stop: 'execution',
				label: 'Vault issued uc3-refund-writer credential',
				seen: f.creds('db_credentials', (e) => e.vaultPath === UC3_WRITER_PATH),
				required: true
			},
			{
				id: 'refund-row',
				stop: 'execution',
				label: 'Refund row written (banking.refunds)',
				failedLabel: 'complete_refund failed',
				seen: [...f.lines(UC3_REFUND_WRITTEN), ...f.toolEnds('complete_refund', 'success')],
				failed: f.toolEnds('complete_refund', 'error'),
				required: true
			},
			// The refund agent does not revoke the writer lease and reports no revoke.
			{ id: 'revoked', stop: 'execution', label: 'Credential revoked', seen: [] },
			{
				id: 'audit-anchor',
				stop: 'result',
				label: 'Audit anchor written to CloudWatch Logs',
				failedLabel: 'Audit anchor not written',
				seen: f.lines(UC3_ANCHOR_OK),
				failed: f.lines(UC3_ANCHOR_FAILED),
				required: true
			}
		);
		const seed = f.of('agent:audit_seed');
		specs.push(
			{ id: 'audit-seed', stop: 'result', label: "Refund's request ID handed to the audit trail", seen: seed, chips: ['request_id'] },
			// Firehose delivers the audit rows to Athena about 60 s after the request
			// (infrastructure/modules/observability/main.tf, buffering_interval = 60), so the
			// correlation happens AFTER this turn and the stream can never report it. Calling it
			// "pending" left a finished refund showing a step that waits for ever; it is a later
			// workshop step, and the flow simply does not claim it.
			{
				id: 'athena',
				stop: 'result',
				label: 'Audit rows correlated in Athena — about 60 s after this turn',
				seen: []
			}
		);
	}
	if (!refundTurn) {
		const readTools = f.tools.filter((t) => t.start || t.end);
		if (readTools.length > 0) {
			specs.push({
				id: 'readonly-cred',
				stop: 'execution',
				label: "Vault issued a read-only database credential to the agent's own login",
				seen: f.creds('db_credentials', (e) => e.issuer === 'Vault' && e.vaultPath !== UC3_WRITER_PATH),
				required: true
			});
			specs.push(...toolSignals(f, 'execution', true));
		}
		// A stream without agent:text_delta is given the page's answer in buildFlow.
		specs.push({
			id: 'answer',
			stop: 'result',
			label: 'Answer returned to the chat',
			seen: f.of('agent:text_delta'),
			failed: f.of('agent:error'),
			failedLabel: 'The turn failed',
			required: true
		});
	}
	return specs;
}

// ---------------------------------------------------------------------------
// Evidence
// ---------------------------------------------------------------------------

function classify(e: AgentEvent, useCase: UseCase, refundTurn: boolean): { kind: string; status: string; line: string; stop: StopId } {
	switch (e.type) {
		case 'agent:thinking':
			return { kind: 'agent.reasoning', status: 'active', line: e.text ?? 'The agent is reasoning.', stop: 'agent' };
		case 'tool_call':
			if (e.status === 'in_progress') {
				return { kind: 'agent.tool_selected', status: 'success', line: `The agent chose ${e.name}.`, stop: 'agent' };
			}
			return {
				kind: 'tool.execute',
				status: e.status,
				line:
					`${e.name} ${e.status === 'success' ? 'returned' : 'failed'}` +
					(typeof e.durationMs === 'number' ? ` after ${e.durationMs} ms.` : '.'),
				stop: 'execution'
			};
		case 'agent:hitl_required':
			return { kind: 'ciba.approval_requested', status: 'waiting', line: e.text ?? 'Approval requested.', stop: 'authorization' };
		case 'agent:hitl_approved':
			return { kind: 'approval', status: 'success', line: e.text ?? 'Approved.', stop: 'authorization' };
		case 'agent:hitl_denied':
			return { kind: 'approval', status: 'denied', line: e.text ?? 'Denied.', stop: 'authorization' };
		case 'agent:hitl_timeout':
			return { kind: 'approval', status: 'timeout', line: e.text ?? 'Timed out.', stop: 'authorization' };
		case 'agent:text_delta':
			return { kind: 'answer', status: 'success', line: `The agent wrote its answer (${e.text.length} characters).`, stop: 'result' };
		case 'agent:done':
			return { kind: 'turn', status: 'success', line: 'The agent finished this turn.', stop: 'result' };
		case 'agent:error':
			return { kind: 'turn', status: 'error', line: e.message, stop: 'result' };
		case 'agent:audit_seed': {
			const leases = e.leases?.length ?? 0;
			return {
				kind: 'audit.seed',
				status: 'success',
				line: `Correlation fields for the audit trail: request ${e.requestId}, ${leases} lease${leases === 1 ? '' : 's'}.`,
				stop: 'result'
			};
		}
		case 'agent:credential':
			return { kind: `credential.${e.kind}`, status: 'issued', line: e.label, stop: credentialStop(e, useCase, refundTurn) };
		case 'agent:narration':
			return classifyLine(e.text, e.accent === 'tool_output', useCase);
		default: {
			// A type outside the contract (a newer agent, or a legacy frame passed in by mistake) is
			// listed as evidence and proves nothing, instead of stopping the whole panel.
			const type = String((e as unknown as { type?: unknown }).type);
			return { kind: 'unknown', status: 'unknown', line: `An event this page does not recognise (${type}).`, stop: 'agent' };
		}
	}
}

function credentialStop(e: AgentCredentialEvent, useCase: UseCase, refundTurn: boolean): StopId {
	switch (e.kind) {
		case 'access_token':
		case 'id_token':
		case 'refresh_token':
			return 'request';
		case 'ciba_token':
		case 'delegated_token':
			return 'authorization';
		case 'k8s_sa_token':
		case 'vault_token':
			if (useCase === 1) return 'authorization';
			return e.label.startsWith(UC2_MCP_OWN) ? 'execution' : 'agent';
		case 'aws_sts_credentials':
			if (useCase === 1 && e.label.startsWith(UC1_KB_KEYS_LABEL)) return 'execution';
			return e.vaultPath === BEDROCK_KEYS_PATH ? 'agent' : 'result';
		case 'db_credentials':
			// In a refund turn the refund agent's read-only credential runs the account owner check.
			return useCase === 3 && refundTurn && e.vaultPath !== UC3_WRITER_PATH ? 'authorization' : 'execution';
		default:
			// A kind outside the contract is still listed, under the agent.
			return 'agent';
	}
}

const LINE_KINDS: { prefix: string; kind: string; status: string; stop: StopId }[] = [
	{ prefix: UC1_NO_USER, kind: 'identity.workload', status: 'success', stop: 'request' },
	{ prefix: UC2_X_VAULT_TOKEN, kind: 'vault.token_presented', status: 'success', stop: 'authorization' },
	{ prefix: UC2_LOOKUP_SELF, kind: 'policy.check', status: 'success', stop: 'authorization' },
	{ prefix: UC2_REVOKED, kind: 'lease.revoked', status: 'success', stop: 'execution' },
	{ prefix: UC2_REVOKE_FAILED, kind: 'lease.revoke', status: 'error', stop: 'execution' },
	{ prefix: UC3_OWNER_OK, kind: 'account.owner_check', status: 'success', stop: 'authorization' },
	{ prefix: UC3_OWNER_REFUSED, kind: 'account.owner_check', status: 'denied', stop: 'authorization' },
	{ prefix: UC3_REFUSED, kind: 'authz.refused', status: 'denied', stop: 'authorization' },
	{ prefix: UC3_TERMS_REFUSED, kind: 'authz.refused', status: 'denied', stop: 'authorization' },
	{ prefix: UC3_CIBA_SENT, kind: 'ciba.initiated', status: 'success', stop: 'authorization' },
	{ prefix: UC3_APPROVAL_POLL, kind: 'approval.poll', status: 'active', stop: 'authorization' },
	{ prefix: UC3_TOKEN_EXCHANGED, kind: 'token.exchange', status: 'success', stop: 'authorization' },
	{ prefix: UC3_WRITER_ISSUED, kind: 'vault.cred_mint', status: 'success', stop: 'execution' },
	{ prefix: UC3_REFUND_WRITTEN, kind: 'db.write', status: 'success', stop: 'execution' },
	{ prefix: UC3_ANCHOR_OK, kind: 'audit.anchor', status: 'success', stop: 'result' },
	{ prefix: UC3_ANCHOR_FAILED, kind: 'audit.anchor', status: 'error', stop: 'result' }
];

function classifyLine(text: string, toolOutput: boolean, useCase: UseCase): { kind: string; status: string; line: string; stop: StopId } {
	const match = LINE_KINDS.find((k) => text.startsWith(k.prefix));
	if (match) return { kind: match.kind, status: match.status, line: text, stop: match.stop };
	if (toolOutput) return { kind: 'tool.output', status: 'success', line: text, stop: 'execution' };
	if (text.startsWith('Writing the answer')) return { kind: 'agent.narration', status: 'success', line: text, stop: 'result' };
	if (useCase === 1 && text.startsWith('Vault issued')) {
		return { kind: 'vault.cred_mint', status: 'success', line: text, stop: text.includes('for calling the model') ? 'agent' : 'execution' };
	}
	if (useCase === 2 && text.startsWith('The MCP server')) return { kind: 'agent.narration', status: 'success', line: text, stop: 'execution' };
	if (useCase === 2 && text.startsWith('Calling ')) return { kind: 'mcp.call', status: 'success', line: text, stop: 'execution' };
	return { kind: 'agent.narration', status: 'success', line: text, stop: 'agent' };
}

function timeLabel(ts: number | undefined, t0: number | undefined): string {
	if (typeof ts !== 'number' || typeof t0 !== 'number') return '';
	const seconds = Math.max(0, ts - t0) / 1000;
	return `+${seconds.toFixed(1)}s`;
}

// ---------------------------------------------------------------------------
// Stories
// ---------------------------------------------------------------------------

type StopState = 'observed' | 'active' | 'waiting' | 'failed' | 'not observed';

function stateOf(stop: { status: FlowStatus; tone: FlowTone }): StopState {
	if (stop.tone === 'failed') return 'failed';
	if (stop.tone === 'waiting') return 'waiting';
	if (stop.status === 'observed') return 'observed';
	if (stop.status === 'not observed') return 'not observed';
	return 'active';
}

const EYEBROW: Record<StopState, string> = {
	observed: 'Complete',
	active: 'In progress',
	waiting: 'In progress',
	failed: 'Stopped',
	'not observed': 'Not observed'
};

const CHIP: Record<StopState, string> = {
	observed: 'Complete',
	active: 'In progress',
	waiting: 'Awaiting approval',
	failed: 'Stopped',
	'not observed': 'Not observed in this flow'
};

function shortId(id: string | undefined): string {
	return id ? id.slice(0, 8) : '';
}

/**
 * The approval's amount. The refund agent sends it as the checked decimal string, e.g. "65.00"
 * (applications/uc3-agent/app/agent.py:977); an older agent sent a JSON number.
 */
function money(amount: JsonValue | undefined, currency: JsonValue | undefined): string | undefined {
	const value = typeof amount === 'number' ? amount : typeof amount === 'string' && /^\d+(\.\d+)?$/.test(amount) ? Number(amount) : NaN;
	if (!Number.isFinite(value)) return undefined;
	if (currency === 'USD') return `$${value.toFixed(2)}`;
	return `${value.toFixed(2)} ${typeof currency === 'string' ? currency : ''}`.trim();
}

function list(items: string[]): string {
	if (items.length <= 1) return items.join('');
	return `${items.slice(0, -1).join(', ')} and ${items.at(-1)}`;
}

/**
 * A failed tool call's reason, in the shape each agent sends it: `{"error": "<text>"}` from the
 * Use Case 1 agent (infrastructure/modules/uc1_agent/agent/app/agent.py:434) and the banking
 * agent (applications/banking-app/agent/app/activity.py:852); the bare text from the refund
 * agent (applications/uc3-agent/app/activity.py:551, via _tool_result_payload at :466).
 */
function toolError(result: JsonValue | undefined): string | undefined {
	if (typeof result === 'string') return result;
	if (result && typeof result === 'object' && !Array.isArray(result) && typeof result.error === 'string') return result.error;
	return undefined;
}

function firstText(seen: Seen[]): string | undefined {
	for (const s of seen) {
		const e = s.event;
		if (e.type === 'agent:narration') return e.text;
		if (e.type === 'agent:error') return e.message;
		if (e.type === 'tool_call') {
			const reason = e.status === 'error' ? toolError(e.result) : undefined;
			if (reason) return reason;
			continue;
		}
		if ('text' in e && typeof e.text === 'string') return e.text;
	}
	return undefined;
}

function claimsOf(seen: Seen[]): JsonObject | undefined {
	for (const s of seen) if (s.event.type === 'agent:credential' && s.event.claims) return s.event.claims;
	return undefined;
}

function sig(signals: BuiltSignal[], id: string): BuiltSignal | undefined {
	return signals.find((s) => s.id === id);
}

function observed(signals: BuiltSignal[], id: string): boolean {
	return sig(signals, id)?.status === 'observed' && sig(signals, id)?.tone === 'ok';
}

function failureText(f: Facts, signals: BuiltSignal[], stop: StopId): string | undefined {
	const failing = signals.find((s) => s.stop === stop && s.tone === 'failed');
	if (!failing) return undefined;
	return firstText(f.list.filter((s) => failing.seenAt.includes(s.at)));
}

function story(f: Facts, id: StopId, state: StopState, signals: BuiltSignal[]): StopStory {
	const base = { eyebrow: EYEBROW[state], chip: CHIP[state] };
	const rid = f.requestId;
	const tools = [...new Set(f.tools.filter((t) => t.start).map((t) => t.name))];

	if (state === 'not observed') {
		const own = signals.filter((s) => s.stop === id);
		const missing = own.filter((s) => s.required && s.status !== 'observed').map((s) => s.label);
		const partly = own.some((s) => s.status === 'observed');
		return {
			...base,
			title: `${STOP_LABELS[id]} not observed`,
			line: partly ? 'Part of this stop was reported; the rest never arrived.' : 'The stream reported nothing for this stop.',
			heading: 'Not observed in this flow.',
			body: missing.length
				? `This turn ended without: ${missing.join('; ')}. The flow does not claim ${missing.length === 1 ? 'it' : 'they'} happened.`
				: 'This turn ended without an event that proves this stop, so the flow does not claim it happened.'
		};
	}
	if (state === 'failed') {
		const text = failureText(f, signals, id);
		const failing = signals.find((s) => s.stop === id && s.tone === 'failed');
		return {
			...base,
			chip: failing?.label ?? 'Stopped',
			title: failing?.label ?? 'Stopped',
			line: 'The flow stopped here.',
			heading: failing?.label ?? 'The flow stopped here.',
			body: text ?? 'The stream reported a failure at this stop.'
		};
	}

	switch (id) {
		case 'request': {
			if (state === 'active') {
				return { ...base, title: 'Sending the question', line: 'Waiting for the agent to report.', heading: 'The question is on its way.', body: 'Nothing has been reported yet.' };
			}
			if (f.useCase === 1) {
				const noUser = observed(signals, 'no-user');
				return {
					...base,
					title: 'Question received',
					line: rid ? `Tagged with request ${shortId(rid)}.` : 'The agent accepted the question.',
					heading: noUser ? 'The request carries no user identity.' : 'The agent accepted the question.',
					body: noUser
						? 'No user is signed in, so the agent answers as itself: its own workload identity governs every step that follows.'
						: 'The agent assigned the request ID that every later step carries.'
				};
			}
			if (f.useCase === 2) {
				const token = sig(signals, 'access-token');
				const sub = claimsOf(f.creds('access_token'))?.sub;
				return {
					...base,
					title: 'Question received',
					line: rid ? `Tagged with request ${shortId(rid)}.` : 'The agent accepted the question.',
					heading: token?.status === 'observed' ? "The signed-in user's token travels with the question." : 'The agent accepted the question.',
					body:
						token?.status === 'observed'
							? `The banking UI sent the question with the signed-in user's access token${typeof sub === 'string' ? ` (sub ${sub})` : ''}. The agent forwards that same token when it calls the MCP server.`
							: 'The agent assigned the request ID that every later step carries.'
				};
			}
			const sub = claimsOf(f.creds('id_token'))?.sub;
			return {
				...base,
				title: 'Request verified',
				line: 'The id_token was checked before anything else.',
				heading: 'The refund agent checks who is asking.',
				body: `The banking UI sent the question with ${typeof sub === 'string' ? `${sub}'s` : "the signed-in user's"} id_token. The agent verified it before doing anything else.`
			};
		}
		case 'agent': {
			if (state === 'active') {
				return { ...base, title: 'Agent is reasoning', line: 'Choosing what to do next.', heading: 'The agent decides which tools it needs.', body: 'No tool has been chosen yet.' };
			}
			const keys = observed(signals, 'model-keys');
			const chose = tools.length > 0 ? `It chose ${list(tools)}.` : 'The stream reported no tool call.';
			return {
				...base,
				title: tools.length > 0 ? `Agent chose ${list(tools)}` : 'Agent reasoned',
				line: keys ? 'Model calls signed with short-lived AWS keys from Vault.' : 'The agent worked out its next step.',
				heading: 'The agent decides which tools it needs.',
				body:
					chose +
					(keys
						? f.useCase === 1
							? ' Its model calls are signed with short-lived AWS keys Vault issued to it.'
							: " Its model calls are signed with short-lived AWS keys Vault issued under the agent's own Kubernetes login, not the user's token."
						: '')
			};
		}
		case 'authorization': {
			if (f.useCase === 1) {
				if (state === 'active') {
					return { ...base, title: 'Signing in to Vault', line: 'Kubernetes service account → Vault.', heading: 'The agent proves who it is.', body: 'Its Vault login has not been reported yet.' };
				}
				const reused = f.creds('k8s_sa_token').some((s) => s.event.type === 'agent:credential' && s.event.label.includes(UC1_SA_REUSED));
				return {
					...base,
					title: 'Signed in to Vault as itself',
					line: 'Kubernetes service account → Vault token.',
					heading: 'The agent proves who it is — not who is asking.',
					body: reused
						? 'It reuses the Vault token it got earlier by presenting its Kubernetes service-account token to Vault.'
						: 'It presented its Kubernetes service-account token to Vault and got back a Vault token.'
				};
			}
			if (f.useCase === 2) {
				if (state === 'active') {
					return { ...base, title: "Presenting the user's token", line: 'Waiting for Vault.', heading: 'Vault decides what this agent may do for this user.', body: 'The MCP server has not reported its Vault read yet.' };
				}
				const policies = observed(signals, 'policies');
				const ceiling = observed(signals, 'ceiling');
				return {
					...base,
					title: "Vault accepted the user's token",
					line: 'X-Vault-Token · no Vault login.',
					heading: 'Vault decides what this agent may do for this user.',
					body:
						"The MCP server presented the user's access token to Vault directly as X-Vault-Token." +
						(policies ? " Vault listed the caller's policies, the human baseline." : '') +
						(ceiling ? " The agent's ceiling was read from its Agent Registry registration; the request gets only what both allow." : '')
				};
			}
			// Use Case 3
			if (state === 'waiting') {
				const details = f.of('agent:hitl_required').at(-1)?.event.details;
				const amount = money(details?.amount, details?.currency);
				const account = typeof details?.account_id === 'string' ? details.account_id : undefined;
				const terms = amount && account ? ` — ${amount} back to ${account} —` : '';
				return {
					...base,
					title: 'Waiting for your approval',
					line: 'IBM Verify pushed this exact refund to your phone.',
					heading: 'The agent cannot approve its own refund.',
					body: `It asked IBM Verify Identity Access for your consent to this one action${terms} as a backchannel sign-in request carrying the refund's details. No credential that can write to the database exists yet; Vault issues one only after you approve.`,
					note: 'Completed steps remain visible as context; future steps stay quiet until they become relevant.'
				};
			}
			if (state === 'active') {
				if (observed(signals, 'approval')) {
					return {
						...base,
						title: 'Approval received',
						line: 'Exchanging it for a delegated token.',
						heading: 'Your approval becomes a token that names both of you.',
						body: 'IBM Verify Identity Access returned the CIBA token after the phone approval. The delegated token has not been reported yet.'
					};
				}
				if (refundPhase(f).complete) {
					return { ...base, title: 'Checking for your approval', line: 'Polling IBM Verify Identity Access.', heading: 'The agent cannot approve its own refund.', body: 'Your approval has not been reported yet.' };
				}
				return { ...base, title: 'Asking for your approval', line: 'Sending the refund to IBM Verify.', heading: 'The agent cannot approve its own refund.', body: 'The approval request has not been reported yet.' };
			}
			const claims = claimsOf(f.creds('delegated_token'));
			const act = claims?.act;
			const actSub = act && typeof act === 'object' && !Array.isArray(act) ? act.sub : undefined;
			const sub = claims?.sub;
			if (observed(signals, 'delegated-token')) {
				return {
					...base,
					title: 'Approval received',
					line: 'Delegated token issued (RFC 8693).',
					heading: 'Your approval became a token that names both of you.',
					body:
						'IBM Verify Identity Access returned the CIBA token after the phone approval, then exchanged it for a delegated token' +
						(typeof sub === 'string' && typeof actSub === 'string' ? `: subject ${sub}, acting party ${actSub}.` : '.')
				};
			}
			return {
				...base,
				title: 'Approval received',
				line: 'The approval was reported.',
				heading: 'The agent cannot approve its own refund.',
				body: 'The stream reported the approval for this refund.'
			};
		}
		case 'execution': {
			if (state === 'active') {
				return { ...base, title: 'Running the tools', line: 'Waiting for short-lived credentials.', heading: 'Vault issues credentials just in time.', body: 'No credential has been reported yet.' };
			}
			if (f.useCase === 1) {
				const issued: string[] = [];
				if (observed(signals, 'db-cred')) issued.push('a database login (database/creds/uc1-readonly)');
				if (observed(signals, 'kb-keys')) issued.push(`AWS keys for reading the knowledge base (${BEDROCK_KEYS_PATH})`);
				return {
					...base,
					title: 'Short-lived credentials issued',
					line: issued.length ? 'Issued for this question only.' : 'The tools returned.',
					heading: 'Vault issues credentials just in time, for this question only.',
					body: (issued.length ? `Vault issued ${list(issued)}. ` : '') + (tools.length ? `${list(tools)} returned.` : '')
				};
			}
			if (f.useCase === 2) {
				const revoked = observed(signals, 'revoked');
				return {
					...base,
					title: revoked ? 'Per-user credential issued and revoked' : 'Per-user credential issued',
					line: revoked ? 'Revoked before the MCP server replied.' : 'Issued to the MCP server.',
					heading: revoked ? 'The database credential lives only as long as the tool call.' : 'Vault issues credentials just in time.',
					body:
						`Vault issued a database credential for ${list(tools)} to the MCP server.` +
						(revoked ? ' The MCP server revoked the lease before it replied.' : '')
				};
			}
			if (sig(signals, 'writer-cred')) {
				return {
					...base,
					title: 'Refund row written',
					line: 'With a uc3-refund-writer credential.',
					heading: 'Vault issues the write credential only to the delegated token.',
					body: 'Vault issued a uc3-refund-writer database credential to the delegated token, and the agent inserted the refund row into banking.refunds with it.'
				};
			}
			return {
				...base,
				title: 'Read-only credential issued',
				line: 'Issued to the agent for this read.',
				heading: 'Reads use a short-lived read-only credential.',
				body: `Vault issued a read-only database credential to the agent's own Vault token${tools.length ? `, and ${list(tools)} returned` : ''}.`
			};
		}
		case 'result': {
			if (state === 'active') {
				return { ...base, title: 'Writing the answer', line: 'Waiting for the result.', heading: 'The result is on its way.', body: 'Nothing has been reported yet.' };
			}
			if (f.useCase === 3 && sig(signals, 'audit-anchor')) {
				// Name only what the stream proved; the full sentence is the mockup's copy.
				const joined = [
					observed(signals, 'approval') ? 'your approval' : '',
					observed(signals, 'delegated-token') ? 'the delegated token' : '',
					observed(signals, 'writer-cred') ? 'the write credential' : '',
					observed(signals, 'refund-row') ? 'the refund row' : ''
				].filter(Boolean);
				const sentence = list(joined);
				return {
					...base,
					title: observed(signals, 'refund-row') ? 'Refund written' : 'Answer returned',
					line: observed(signals, 'audit-anchor') && observed(signals, 'audit-seed') ? 'Every system logged the same request ID.' : 'The agent replied in the chat.',
					heading: observed(signals, 'refund-row') ? 'The refund completed with a correlated audit trail.' : 'The agent answered.',
					body: sentence
						? `${sentence.charAt(0).toUpperCase()}${sentence.slice(1)} can be joined through one request ID.`
						: 'The stream reported none of the refund steps.'
				};
			}
			if (f.useCase === 3) {
				return { ...base, title: 'Answer returned', line: 'The agent replied in the chat.', heading: 'The agent answered.', body: 'The answer reached the chat.' };
			}
			const seed = observed(signals, 'audit-seed');
			return {
				...base,
				title: 'Answer written',
				line: rid ? `Request ${shortId(rid)}.` : 'The answer reached the chat.',
				heading: seed ? 'The answer and its audit trail share one request ID.' : 'The agent answered.',
				body: seed
					? 'The agent reported its request ID and the lease IDs Vault issued for this answer.'
					: 'The answer reached the chat.'
			};
		}
	}
}

// ---------------------------------------------------------------------------
// The flow
// ---------------------------------------------------------------------------

const REQUEST_LABELS: Record<UseCase, string> = { 1: 'Ask', 2: 'Banking', 3: 'Refund' };

/**
 * The Technical view's rows for a refund turn: the approved mockup's rows, in its order
 * (Security Flow · Technical view, complete). A row the turn does not produce is left out,
 * so a refund waiting for approval lists only "Approval received".
 */
const REFUND_TECHNICAL_ROWS = ['approval', 'delegated-token', 'writer-cred', 'refund-row', 'audit-anchor', 'revoked', 'athena'];

/**
 * The five stops, their signals and the evidence for one turn.
 *
 * `events` are the turn's events in the order they arrived. `context` carries what the page
 * itself knows: the question, when it was sent, whether the stream has ended, and the answer
 * it received (the evidence for a refund stream from before agent:text_delta).
 */
export function buildFlow(useCase: UseCase, events: readonly AgentEvent[], context: FlowContext = {}): Flow {
	// Every agent ends a turn with agent:done; context.done covers a stream from before that.
	const done = context.done === true || events.some((e) => e.type === 'agent:done');
	const f = new Facts(useCase, events, done, context);
	const phase = useCase === 3 ? refundPhase(f) : { initiate: false, complete: false };
	const refundTurn = phase.initiate || phase.complete;

	// Evidence rows: what the page sent, every event in arrival order, what the page received.
	// Times count from the agent's first event. The page's own send time is on the browser's
	// clock and `ts` on the pod's, so mixing them would show skew as latency (or clamp to 0).
	const t0 = f.list.find((s) => typeof s.event.ts === 'number')?.event.ts;
	const evidence: EvidenceRow[] = [];
	const rowOf = new Map<number, number>();
	if (context.question) {
		evidence.push({
			index: 0,
			t: '',
			src: 'local:sendMessage',
			kind: 'user.request',
			status: 'success',
			line: context.question,
			stop: 'request',
			raw: { question: context.question, ...(context.startedAt !== undefined ? { startedAt: context.startedAt } : {}) }
		});
	}
	for (const s of f.list) {
		const c = classify(s.event, useCase, refundTurn);
		rowOf.set(s.at, evidence.length);
		evidence.push({
			index: evidence.length,
			t: timeLabel(s.event.ts, t0),
			src: s.event.type,
			kind: c.kind,
			status: c.status,
			line: c.line,
			stop: c.stop,
			raw: s.event as unknown as JsonValue
		});
	}
	// The page's answer is evidence only when the stream itself carried none, so the answer is
	// listed once.
	const streamAnswered = events.some((e) => e.type === 'agent:text_delta');
	const answerRow = useCase === 3 && context.answer && !streamAnswered ? evidence.length : -1;
	if (answerRow >= 0) {
		evidence.push({
			index: answerRow,
			t: '',
			src: 'local:answer',
			kind: 'answer',
			status: 'success',
			line: `The chat received the agent's answer (${context.answer!.length} characters).`,
			stop: 'result',
			raw: { answer: context.answer! }
		});
	}

	const specs = useCase === 1 ? useCase1Signals(f) : useCase === 2 ? useCase2Signals(f) : useCase3Signals(f);
	const signals = specs.map((spec) => toSignal(spec, done));
	for (const s of signals) s.evidence = s.seenAt.map((at) => rowOf.get(at)).filter((i): i is number => i !== undefined);
	const answer = sig(signals, 'answer');
	if (useCase === 3 && answer && answerRow >= 0) {
		answer.status = 'observed';
		answer.evidence = [answerRow];
	}

	// A question the page sent is the page's own evidence of the Request stop's first step.
	if (context.question) {
		signals.unshift({
			id: 'question',
			stop: 'request',
			label: 'Question sent by the page',
			status: 'observed',
			tone: 'ok',
			evidence: [0],
			seenAt: [],
			required: false,
			chips: []
		});
	}

	// An approval that is still open holds the flow at Authorization, even after the turn ends.
	const waiting = signals.some((s) => s.tone === 'waiting' && s.stop === 'authorization');

	const stops: Stop[] = STOP_IDS.map((id, i) => {
		const own = signals.filter((s) => s.stop === id);
		const required = own.filter((s) => s.required);
		let status: FlowStatus;
		let tone: FlowTone = 'ok';
		if (own.some((s) => s.tone === 'failed')) {
			status = 'observed';
			tone = 'failed';
		} else if (id === 'authorization' && own.some((s) => s.tone === 'waiting')) {
			status = 'pending';
			tone = 'waiting';
		} else if (required.length > 0 ? required.every((s) => s.status === 'observed') : own.some((s) => s.status === 'observed')) {
			status = 'observed';
		} else if (waiting && i > STOP_IDS.indexOf('authorization')) {
			status = 'pending';
		} else {
			status = done ? 'not observed' : 'pending';
		}
		return { id, label: STOP_LABELS[id], status, tone, story: undefined as unknown as StopStory, chips: [], ids: [] };
	});

	// Signals after an open approval wait with it: they are pending, not "not observed".
	if (waiting) {
		const auth = STOP_IDS.indexOf('authorization');
		for (const s of signals) {
			if (STOP_IDS.indexOf(s.stop) > auth && s.status === 'not observed') s.status = 'pending';
		}
	}

	let focusIndex: number;
	const failedIndex = stops.findIndex((s) => s.tone === 'failed');
	if (waiting) focusIndex = STOP_IDS.indexOf('authorization');
	else if (failedIndex >= 0) focusIndex = failedIndex;
	else if (!done) {
		const next = stops.findIndex((s) => s.status !== 'observed');
		focusIndex = next >= 0 ? next : stops.length - 1;
	} else if (stops[stops.length - 1].status !== 'observed') {
		// The turn ended short of a result: focus the stop right after the last one that reported.
		let last = -1;
		stops.forEach((s, i) => {
			if (s.status === 'observed') last = i;
		});
		focusIndex = Math.min(last + 1, stops.length - 1);
	} else focusIndex = stops.length - 1;

	const hitlDetails = f.of('agent:hitl_required').at(-1)?.event.details ?? f.of('agent:hitl_approved').at(-1)?.event.details;
	const authReqId = typeof hitlDetails?.auth_req_id === 'string' ? hitlDetails.auth_req_id : undefined;
	for (const stop of stops) {
		stop.story = story(f, stop.id, stateOf(stop), signals);
		stop.chips = [...new Set(signals.filter((s) => s.stop === stop.id).flatMap((s) => s.chips))];
		if (stop.id === 'authorization' && authReqId) stop.ids.push({ label: 'auth_req_id', value: authReqId });
		if (f.requestId) stop.ids.push({ label: 'request', value: f.requestId });
	}

	const shown: Signal[] = signals.map(({ id, stop, label, status, tone, note, evidence: ev }) => ({ id, stop, label, status, tone, note, evidence: ev }));
	const technical =
		useCase === 3 && refundTurn
			? REFUND_TECHNICAL_ROWS.flatMap((row) => shown.filter((s) => s.id === row))
			: shown;

	return {
		useCase,
		requestLabel: REQUEST_LABELS[useCase],
		question: context.question,
		requestId: f.requestId,
		done,
		waiting,
		focus: STOP_IDS[focusIndex],
		stops,
		signals: shown,
		technical,
		evidence
	};
}

/** Chips of every stop up to and including `upTo`, request_id first: the Technical view's chip row. */
export function chipsUpTo(flow: Flow, upTo: StopId): string[] {
	const last = STOP_IDS.indexOf(upTo);
	const all = flow.stops.filter((_, i) => i <= last).flatMap((s) => s.chips);
	const unique = [...new Set(all)];
	return unique.includes('request_id') ? ['request_id', ...unique.filter((c) => c !== 'request_id')] : unique;
}
