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
 *   - in payload fields (tool `args`/`result`, HITL `details`, audit `leases`/`claims`)
 *     any key that names a configuration secret (an OAuth client secret, a SCIM,
 *     admin or LDAP password, Vault's root token or unseal/recovery keys) is
 *     removed with its value, however deeply it is nested.
 * Values are never rewritten. Credentials issued during a turn (tokens, Vault
 * tokens, database and AWS credentials) reach the browser in full, by design:
 * the workshop shows what each use case does as it happens.
 *
 * Example frames, as the browser receives them:
 *
 *     data: {"type":"agent:narration","glyph":"▶","text":"Exchanging the user's token with Vault","requestId":"req-7f3a"}
 *     data: {"type":"tool_call","toolCallId":"t1","name":"get_accounts","status":"success","result":{"lease_id":"database/creds/...","ttl_seconds":300},"durationMs":412}
 *     data: {"type":"agent:credential","kind":"vault_token","label":"The agent's Vault token","issuer":"Vault","value":"hvs.<the full token>","ttlSeconds":300}
 *     data: {"type":"agent:text_delta","text":"Your checking balance is ..."}
 *     data: {"type":"agent:done","requestId":"req-7f3a"}
 *
 * This module holds types and constants only, so browser code can import it.
 */

/** Any value JSON can carry. Payload fields are typed as this. */
export type JsonValue = string | number | boolean | null | JsonValue[] | JsonObject;
export interface JsonObject {
	[key: string]: JsonValue;
}

/** `agent:narration` glyphs: ▶ marks an agent step, ⚡ marks tool output. */
export const NARRATION_GLYPHS = ['▶', '⚡'] as const;
export type NarrationGlyph = (typeof NARRATION_GLYPHS)[number];

export const TOOL_CALL_STATUSES = ['in_progress', 'success', 'error'] as const;
export type ToolCallStatus = (typeof TOOL_CALL_STATUSES)[number];

/** Every kind of credential a turn can issue and `agent:credential` can show. */
export const CREDENTIAL_KINDS = [
	'access_token',
	'id_token',
	'refresh_token',
	'ciba_token',
	'delegated_token',
	'k8s_sa_token',
	'vault_token',
	'db_credentials',
	'aws_sts_credentials'
] as const;
export type CredentialKind = (typeof CREDENTIAL_KINDS)[number];

/** Who issued a credential. */
export const CREDENTIAL_ISSUERS = ['IBM Verify Identity Access', 'Vault', 'Kubernetes', 'AWS STS (via Vault)'] as const;
export type CredentialIssuer = (typeof CREDENTIAL_ISSUERS)[number];

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
	/** The tool's arguments, without configuration-secret keys. */
	args?: JsonValue;
	/** The tool's result, without configuration-secret keys. */
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
	/** What is being approved (e.g. amount, currency, transaction), without configuration-secret keys. */
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
	 * The lease of every credential Vault issued for this turn, e.g.
	 * `{ lease_id, vault_path, ttl_seconds }`, without configuration-secret keys.
	 */
	leases?: JsonObject[];
	/**
	 * Decoded claims of the token the agent acted with (sub, scope, jti, iss,
	 * aud, exp, act), without configuration-secret keys.
	 */
	claims?: JsonObject;
}

/**
 * One credential issued during this turn, shown IN FULL as it is issued: a
 * user's sign-in or refund token, a Vault token, the Kubernetes service-account
 * JWT an agent logs in to Vault with, database credentials or AWS STS keys.
 *
 * Exactly one of `value` (a single token) or `fields` (the parts of a
 * multi-part credential) is present. A frame with both, or with neither, is
 * dropped. Every other optional field is present only when it exists for that
 * credential.
 */
export interface AgentCredentialEvent extends EventEnvelope {
	type: 'agent:credential';
	kind: CredentialKind;
	/** Plain English, e.g. "Oscar's delegated token from the RFC 8693 exchange". */
	label: string;
	issuer: CredentialIssuer;
	/** The full token, for a single-value credential. */
	value?: string;
	/**
	 * The full parts of a multi-part credential: `{ username, password }` for
	 * db_credentials, `{ access_key_id, secret_access_key, session_token }` for
	 * aws_sts_credentials. Every value is a string.
	 */
	fields?: Record<string, string>;
	/** The decoded payload of `value` when it is a JWT. Decoded, NOT verified. */
	claims?: JsonObject;
	/** The Vault path the credential was read from, e.g. "database/creds/uc1-readonly". */
	vaultPath?: string;
	/** The Vault lease the credential belongs to. */
	leaseId?: string;
	/** How long the credential lives, in seconds, as its issuer reported it. */
	ttlSeconds?: number;
	/** When the credential expires: milliseconds since the Unix epoch (UTC). */
	expiresAt?: number;
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
	| AgentAuditSeedEvent
	| AgentCredentialEvent;

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
