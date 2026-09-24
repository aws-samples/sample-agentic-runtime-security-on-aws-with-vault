/**
 * agent-events.ts — the one event contract every agent chat streams to the browser.
 *
 * Wire format
 * -----------
 * Server-Sent Events. Every event is exactly ONE frame:
 *
 *     data: <json>\n\n
 *
 * where <json> is one of the objects below, discriminated by `type`. No
 * `event:`, `id:` or `retry:` lines are ever sent.
 *
 * Who guarantees it
 * -----------------
 * The UI server routes (/api/chat, /api/uc3-chat and /api/ask) never hand an
 * agent's stream to the browser directly. Every frame passes through
 * $lib/server/activity-filter first, so what a browser receives is this
 * contract and nothing more:
 *   - an event type not listed here is dropped;
 *   - a field not listed on its type is dropped;
 *   - a frame that is not valid JSON, or that is missing a required field, is dropped;
 *   - every string has raw tokens (JWTs, Vault tokens) replaced by REDACTED_TOKEN;
 *   - payload fields (tool `args`/`result`, HITL `details`, audit `leases`/`claims`)
 *     are deep-scrubbed: any key named like a secret (password, secret, token,
 *     private key, api key, ...) is removed, however deeply it is nested.
 *
 * Example frames, as the browser receives them:
 *
 *     data: {"type":"agent:narration","glyph":"▶","text":"Exchanging the user's token with Vault","requestId":"req-7f3a"}
 *     data: {"type":"tool_call","toolCallId":"t1","name":"get_accounts","status":"success","result":{"lease_id":"database/creds/...","ttl_seconds":300},"durationMs":412}
 *     data: {"type":"agent:text_delta","text":"Your checking balance is ..."}
 *     data: {"type":"agent:done","requestId":"req-7f3a"}
 *
 * This module holds types and constants only, so browser code can import it.
 */

/** Any value JSON can carry. Payload fields are typed as this after scrubbing. */
export type JsonValue = string | number | boolean | null | JsonValue[] | JsonObject;
export interface JsonObject {
	[key: string]: JsonValue;
}

/** What a raw token (JWT or Vault token) is replaced with before it reaches the browser. */
export const REDACTED_TOKEN = '[token redacted]';

/** `agent:narration` glyphs: ▶ marks an agent step, ⚡ marks tool output. */
export const NARRATION_GLYPHS = ['▶', '⚡'] as const;
export type NarrationGlyph = (typeof NARRATION_GLYPHS)[number];

export const TOOL_CALL_STATUSES = ['in_progress', 'success', 'error'] as const;
export type ToolCallStatus = (typeof TOOL_CALL_STATUSES)[number];

/** Fields any current (non-legacy) event may carry. */
export interface EventEnvelope {
	/** Correlation ID of the chat turn. Matches `request_id` in the audit logs. */
	requestId?: string;
	/** When the agent emitted the event: milliseconds since the Unix epoch (UTC). */
	ts?: number;
}

// ---------------------------------------------------------------------------
// Current events
// ---------------------------------------------------------------------------

/** The agent is reasoning about what to do next. */
export interface AgentThinkingEvent extends EventEnvelope {
	type: 'agent:thinking';
	/** Optional short label, e.g. "Planning the next step". */
	text?: string;
}

/** One line for the Agent Log. */
export interface AgentNarrationEvent extends EventEnvelope {
	type: 'agent:narration';
	glyph: NarrationGlyph;
	text: string;
	/** Set to 'tool_output' when the line reports what a tool returned. */
	accent?: 'tool_output';
}

/**
 * A tool call's lifecycle. The same `toolCallId` is sent once with status
 * 'in_progress', then again with 'success' or 'error'.
 */
export interface ToolCallEvent extends EventEnvelope {
	type: 'tool_call';
	toolCallId: string;
	name: string;
	status: ToolCallStatus;
	/** The tool's arguments, deep-scrubbed. */
	args?: JsonValue;
	/** The tool's result, deep-scrubbed. */
	result?: JsonValue;
	/** Wall-clock time the call took, in milliseconds. */
	durationMs?: number;
}

/** Fields shared by the four human-in-the-loop approval events. */
interface HitlFields extends EventEnvelope {
	/** The tool call that asked for the approval. */
	toolCallId?: string;
	/** Plain-English line for the log, e.g. "Approval pushed to the user's IBM Verify app". */
	text?: string;
	/** What is being approved (e.g. amount, currency, transaction), deep-scrubbed. */
	details?: JsonObject;
}

/** The agent is waiting for a person to approve an action. */
export interface HitlRequiredEvent extends HitlFields {
	type: 'agent:hitl_required';
}
export interface HitlApprovedEvent extends HitlFields {
	type: 'agent:hitl_approved';
}
export interface HitlDeniedEvent extends HitlFields {
	type: 'agent:hitl_denied';
}
export interface HitlTimeoutEvent extends HitlFields {
	type: 'agent:hitl_timeout';
}

/** A piece of the answer text. Pieces are appended in the order they arrive. */
export interface AgentTextDeltaEvent extends EventEnvelope {
	type: 'agent:text_delta';
	text: string;
}

/** The turn is finished. Nothing follows it. */
export interface AgentDoneEvent extends EventEnvelope {
	type: 'agent:done';
}

/** The turn failed. `agent:done` still follows it. */
export interface AgentErrorEvent extends EventEnvelope {
	type: 'agent:error';
	message: string;
}

/**
 * The live correlation fields for this turn: what the Audit Trace card shows
 * straight away, before the matching audit rows land in Athena.
 */
export interface AgentAuditSeedEvent extends EventEnvelope {
	type: 'agent:audit_seed';
	/** Required here: it is the key that joins this turn to its audit rows. */
	requestId: string;
	/** Vault role the agent authenticated as. */
	vaultRole?: string;
	/** Database role the issued credentials belong to. */
	dbRole?: string;
	/**
	 * Every credential Vault issued for this turn, deep-scrubbed, e.g.
	 * `{ lease_id, vault_path, ttl_seconds }`. Never the credential itself.
	 */
	leases?: JsonObject[];
	/**
	 * Decoded claims of the token the agent acted with (sub, scope, jti, iss,
	 * aud, exp, act), deep-scrubbed. Never the token itself.
	 */
	claims?: JsonObject;
}

export type AgentEvent =
	| AgentThinkingEvent
	| AgentNarrationEvent
	| ToolCallEvent
	| HitlRequiredEvent
	| HitlApprovedEvent
	| HitlDeniedEvent
	| HitlTimeoutEvent
	| AgentTextDeltaEvent
	| AgentDoneEvent
	| AgentErrorEvent
	| AgentAuditSeedEvent;

// ---------------------------------------------------------------------------
// Legacy events — what the agents emit today. They reach the browser exactly
// as before (type, role, content) until the agents switch to the events above.
// ---------------------------------------------------------------------------

export interface LegacyToolPlanningEvent {
	type: 'tool_planning';
	role?: 'ai';
	content: string;
}

/** Today's agents send the whole answer as one delta. */
export interface LegacyDeltaEvent {
	type: 'delta';
	role?: 'ai';
	content: string;
}

export interface LegacyEndEvent {
	type: 'end';
}

export interface LegacyErrorEvent {
	type: 'error';
	content: string;
}

export type LegacyAgentEvent = LegacyToolPlanningEvent | LegacyDeltaEvent | LegacyEndEvent | LegacyErrorEvent;

/** Every event the browser can receive. */
export type StreamEvent = AgentEvent | LegacyAgentEvent;
export type StreamEventType = StreamEvent['type'];
