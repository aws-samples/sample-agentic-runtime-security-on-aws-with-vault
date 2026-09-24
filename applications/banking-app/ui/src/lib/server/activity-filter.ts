/**
 * activity-filter.ts — the one gate every agent event passes through on its way
 * to the browser.
 *
 * The agents run inside the cluster and hold real credentials: the user's
 * access token, Vault tokens, database passwords. Whatever an agent streams —
 * including text a model was tricked into writing — this filter decides what a
 * browser may see. It fails closed: anything it does not recognise is dropped.
 *
 * Two layers
 * ----------
 * 1. Envelope (strict allowlist). Each event type has a fixed list of top-level
 *    fields (SCHEMAS below, checked at compile time against $lib/agent-events).
 *    Unknown event types are dropped. Unknown fields are dropped. A frame
 *    missing a required field, or carrying one of the wrong type, is dropped.
 *
 * 2. Payload (deep scrub). Fields that carry arbitrary data — tool `args` and
 *    `result`, HITL `details`, audit `leases` and `claims` — are walked
 *    recursively:
 *      - a key named like a secret is removed (SECRET_KEY_SUBSTRINGS,
 *        SECRET_KEY_NAMES), however deep it sits;
 *      - __proto__, constructor and prototype keys are removed (PROTOTYPE_KEYS);
 *      - correlation keys (CORRELATION_KEYS) are always kept, so the audit
 *        story survives, but their values are still scrubbed;
 *      - every string, in the payload AND in the envelope, has raw tokens
 *        replaced by REDACTED_TOKEN: JWTs (also when embedded in a longer
 *        string) and Vault tokens.
 *
 * Streaming
 * ---------
 * createActivityFilter() is a TransformStream. It parses Server-Sent Events
 * incrementally: frames split across network chunks are reassembled, each
 * complete frame is sanitised and re-emitted at once, and the body as a whole
 * is never buffered. Pending text is capped (MAX_EVENT_CHARS) so a frame that
 * never ends cannot grow memory without bound.
 *
 * What it does NOT catch: a secret written as free text inside a string, such
 * as "the password is hunter2". Keys are scrubbed by name and strings by token
 * shape; prose is not interpreted.
 */

import {
	NARRATION_GLYPHS,
	REDACTED_TOKEN,
	TOOL_CALL_STATUSES,
	type JsonObject,
	type JsonValue,
	type StreamEvent,
	type StreamEventType
} from '$lib/agent-events';

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

/** Largest single event (its data, or one pending line) the parser will hold. */
const MAX_EVENT_CHARS = 1024 * 1024;
/** Deepest payload nesting kept. Anything deeper is dropped, not passed through. */
const MAX_PAYLOAD_DEPTH = 32;
/** Longest identifier (requestId, toolCallId, tool name, role) accepted. */
const MAX_ID_CHARS = 256;

// ---------------------------------------------------------------------------
// Key rules for payload data
// ---------------------------------------------------------------------------

/**
 * A key is secret-named when, lowercased with every non-alphanumeric removed
 * (so client_secret, clientSecret and Client-Secret all read "clientsecret"),
 * it CONTAINS one of these. Covers password, client_secret, secret_id,
 * access_token, refresh_token, id_token, client_token, session_token,
 * private_key, api_key, x-api-key and the like.
 */
const SECRET_KEY_SUBSTRINGS = ['password', 'passwd', 'passphrase', 'secret', 'token', 'privatekey', 'apikey'] as const;

/**
 * HTTP header names that carry credentials. Matched EXACTLY after the same
 * normalisation, so `authorization_details` (the refund terms a person
 * approves) is not caught by `authorization`.
 */
const SECRET_KEY_NAMES: ReadonlySet<string> = new Set(['authorization', 'proxyauthorization', 'cookie', 'setcookie']);

/**
 * Correlation keys the audit story depends on. Always kept, even if a secret
 * rule would match, and their values are still scrubbed.
 */
const CORRELATION_KEYS: ReadonlySet<string> = new Set([
	'lease_id',
	'lease_duration_seconds',
	'ttl_seconds',
	'vault_path',
	'vault_role',
	'db_role',
	'user_sub',
	'sub',
	'scope',
	'jti',
	'request_id',
	'iss',
	'aud',
	'exp',
	'act'
]);

/**
 * Keys that change an object's prototype when browser code merges a payload
 * with Object.assign or a recursive merge. Never forwarded.
 */
const PROTOTYPE_KEYS: ReadonlySet<string> = new Set(['__proto__', 'constructor', 'prototype']);

function isSecretKey(key: string): boolean {
	const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, '');
	if (SECRET_KEY_NAMES.has(normalized)) return true;
	return SECRET_KEY_SUBSTRINGS.some((term) => normalized.includes(term));
}

// ---------------------------------------------------------------------------
// String rules: raw tokens
// ---------------------------------------------------------------------------

/**
 * A run of characters a compact JWT is made of: base64url plus the dots
 * between its parts. Tokens are found run by run instead of with one regex over
 * the whole string, because a pattern like `eyJ[\w-]*\.[\w-]*\.[\w-]*`
 * backtracks quadratically on hostile input and would stall the server.
 */
const TOKEN_CHAR_RUN = /[A-Za-z0-9_.-]+/g;

/**
 * Vault tokens, as HashiCorp documents them for Vault 1.10 and later: a type
 * prefix (hvs. service, hvb. batch, hvr. recovery) followed by 24 or more
 * random characters. https://developer.hashicorp.com/vault/docs/concepts/tokens#token-prefixes
 */
const VAULT_TOKEN = /hv[sbr]\.[A-Za-z0-9_-]{24,}/g;

/**
 * Within one run, a JWT starts at "eyJ" (base64url for `{"`, the opening of
 * its JSON header) and has at least two more dot-separated parts: three for a
 * signed JWT, five for an encrypted one. Everything from "eyJ" to the end of
 * the run is replaced, so a token glued onto other characters is still caught.
 */
function redactRun(run: string, stats: FilterStats): string {
	let out = run;
	const start = out.indexOf('eyJ');
	if (start !== -1) {
		const dots = out.slice(start).split('.').length - 1;
		if (dots >= 2) {
			out = out.slice(0, start) + REDACTED_TOKEN;
			stats.tokensRedacted++;
		}
	}
	if (out.includes('hv')) {
		out = out.replace(VAULT_TOKEN, () => {
			stats.tokensRedacted++;
			return REDACTED_TOKEN;
		});
	}
	return out;
}

function scrubString(value: string, stats: FilterStats): string {
	if (!value.includes('eyJ') && !value.includes('hv')) return value;
	return value.replace(TOKEN_CHAR_RUN, (run) => redactRun(run, stats));
}

// ---------------------------------------------------------------------------
// Payload deep scrub
// ---------------------------------------------------------------------------

function isJsonObject(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Returns a scrubbed copy of `value`, or undefined when nothing of it may pass.
 * The input is only ever read; a new structure is built from what survives.
 */
function scrubValue(value: unknown, depth: number, stats: FilterStats): JsonValue | undefined {
	if (typeof value === 'string') return scrubString(value, stats);
	if (typeof value === 'number') return Number.isFinite(value) ? value : undefined;
	if (typeof value === 'boolean' || value === null) return value;
	if (depth >= MAX_PAYLOAD_DEPTH) {
		stats.deepValuesDropped++;
		return undefined;
	}
	if (Array.isArray(value)) {
		const out: JsonValue[] = [];
		for (const item of value) {
			const scrubbed = scrubValue(item, depth + 1, stats);
			if (scrubbed !== undefined) out.push(scrubbed);
		}
		return out;
	}
	if (isJsonObject(value)) {
		const entries: [string, JsonValue][] = [];
		for (const [key, item] of Object.entries(value)) {
			if (PROTOTYPE_KEYS.has(key)) {
				stats.keysRemoved++;
				continue;
			}
			if (!CORRELATION_KEYS.has(key)) {
				// A key can itself be a token; a key that needed redacting is dropped.
				if (isSecretKey(key) || scrubString(key, stats) !== key) {
					stats.keysRemoved++;
					continue;
				}
			}
			const scrubbed = scrubValue(item, depth + 1, stats);
			if (scrubbed !== undefined) entries.push([key, scrubbed]);
		}
		return Object.fromEntries(entries);
	}
	return undefined;
}

/**
 * Deep-scrubs a JSON body that is not a stream, e.g. the Use Case 1 agent's
 * `{ answer, sources, credential_metadata }` reply. Same rules as payload data.
 */
export function scrubJson(value: unknown): JsonValue | undefined {
	return scrubValue(value, 0, newStats());
}

/**
 * Scrubs an agent's error body before it is shown to the user. A JSON body
 * gets the payload rules; anything else gets the string rules.
 */
export function scrubErrorText(text: string): string {
	const stats = newStats();
	try {
		const scrubbed = scrubValue(JSON.parse(text), 0, stats);
		return scrubbed === undefined ? '' : JSON.stringify(scrubbed);
	} catch {
		return scrubString(text, stats);
	}
}

// ---------------------------------------------------------------------------
// Envelope allowlist
// ---------------------------------------------------------------------------

type FieldSpec =
	| { kind: 'string'; maxLength?: number }
	| { kind: 'enum'; values: readonly string[] }
	| { kind: 'number'; min?: number }
	/** Any JSON value, deep-scrubbed. */
	| { kind: 'json' }
	/** A JSON object, deep-scrubbed. */
	| { kind: 'object' }
	/** An array of JSON objects, deep-scrubbed; non-object items are dropped. */
	| { kind: 'objectArray' };

type FieldRule = FieldSpec & { required: boolean };

/**
 * The allowlist for one event type: exactly one rule per field of the TS type
 * (besides `type`), and `required` must match the field's optionality. Adding
 * a field or an event type to $lib/agent-events without a rule here fails
 * `npm run check`, so the allowlist and the contract cannot drift apart.
 */
type FieldRules<E> = {
	[F in Exclude<keyof E, 'type'>]-?: FieldSpec & { required: {} extends Pick<E, F> ? false : true };
};
type Schemas = { [T in StreamEventType]: FieldRules<Extract<StreamEvent, { type: T }>> };

const ENVELOPE = {
	requestId: { kind: 'string', maxLength: MAX_ID_CHARS, required: false },
	ts: { kind: 'number', min: 0, required: false }
} as const;

const HITL = {
	...ENVELOPE,
	toolCallId: { kind: 'string', maxLength: MAX_ID_CHARS, required: false },
	text: { kind: 'string', required: false },
	details: { kind: 'object', required: false }
} as const;

const LEGACY_ROLE = { kind: 'enum', values: ['ai'], required: false } as const;

const SCHEMAS: Schemas = {
	'agent:thinking': { ...ENVELOPE, text: { kind: 'string', required: false } },
	'agent:narration': {
		...ENVELOPE,
		glyph: { kind: 'enum', values: NARRATION_GLYPHS, required: true },
		text: { kind: 'string', required: true },
		accent: { kind: 'enum', values: ['tool_output'], required: false }
	},
	tool_call: {
		...ENVELOPE,
		toolCallId: { kind: 'string', maxLength: MAX_ID_CHARS, required: true },
		name: { kind: 'string', maxLength: MAX_ID_CHARS, required: true },
		status: { kind: 'enum', values: TOOL_CALL_STATUSES, required: true },
		args: { kind: 'json', required: false },
		result: { kind: 'json', required: false },
		durationMs: { kind: 'number', min: 0, required: false }
	},
	'agent:hitl_required': HITL,
	'agent:hitl_approved': HITL,
	'agent:hitl_denied': HITL,
	'agent:hitl_timeout': HITL,
	'agent:text_delta': { ...ENVELOPE, text: { kind: 'string', required: true } },
	'agent:done': ENVELOPE,
	'agent:error': { ...ENVELOPE, message: { kind: 'string', required: true } },
	'agent:audit_seed': {
		...ENVELOPE,
		requestId: { kind: 'string', maxLength: MAX_ID_CHARS, required: true },
		vaultRole: { kind: 'string', maxLength: MAX_ID_CHARS, required: false },
		dbRole: { kind: 'string', maxLength: MAX_ID_CHARS, required: false },
		leases: { kind: 'objectArray', required: false },
		claims: { kind: 'object', required: false }
	},

	// Legacy events: exactly type, role and content, as today's dashboard reads them.
	tool_planning: { role: LEGACY_ROLE, content: { kind: 'string', required: true } },
	delta: { role: LEGACY_ROLE, content: { kind: 'string', required: true } },
	end: {},
	error: { content: { kind: 'string', required: true } }
};

/**
 * Lookup by Map, never by indexing a plain object: `SCHEMAS["constructor"]`
 * would return Object.prototype's function and let an unknown type through.
 */
const SCHEMA_BY_TYPE: ReadonlyMap<string, ReadonlyArray<[string, FieldRule]>> = new Map(
	Object.entries(SCHEMAS).map(([type, rules]) => [type, Object.entries(rules as Record<string, FieldRule>)])
);

/** Returns the field's sanitised value, or undefined when it fails its rule. */
function sanitizeField(value: unknown, rule: FieldRule, stats: FilterStats): JsonValue | undefined {
	switch (rule.kind) {
		case 'string':
			if (typeof value !== 'string') return undefined;
			if (rule.maxLength !== undefined && value.length > rule.maxLength) return undefined;
			return scrubString(value, stats);
		case 'enum':
			return typeof value === 'string' && rule.values.includes(value) ? value : undefined;
		case 'number':
			if (typeof value !== 'number' || !Number.isFinite(value)) return undefined;
			return rule.min !== undefined && value < rule.min ? undefined : value;
		case 'json':
			return scrubValue(value, 0, stats);
		case 'object':
			return isJsonObject(value) ? scrubValue(value, 0, stats) : undefined;
		case 'objectArray':
			return Array.isArray(value) ? scrubValue(value.filter(isJsonObject), 0, stats) : undefined;
	}
}

/**
 * Builds the event the browser may see from one parsed frame, or returns null
 * to drop the frame. The output is built from the schema's fields, never from
 * the input's keys, so an unlisted field cannot pass by construction.
 */
function sanitizeEvent(parsed: unknown, stats: FilterStats): StreamEvent | null {
	if (!isJsonObject(parsed) || typeof parsed.type !== 'string') {
		stats.invalid++;
		return null;
	}
	const rules = SCHEMA_BY_TYPE.get(parsed.type);
	if (!rules) {
		stats.unknownType++;
		return null;
	}
	const event: Record<string, JsonValue> = { type: parsed.type };
	for (const [field, rule] of rules) {
		const value = Object.hasOwn(parsed, field) ? sanitizeField(parsed[field], rule, stats) : undefined;
		if (value === undefined) {
			if (rule.required) {
				stats.invalid++;
				return null;
			}
			continue;
		}
		event[field] = value;
	}
	return event as unknown as StreamEvent;
}

// ---------------------------------------------------------------------------
// The streaming filter
// ---------------------------------------------------------------------------

interface FilterStats {
	forwarded: number;
	malformed: number;
	invalid: number;
	unknownType: number;
	oversize: number;
	unterminated: number;
	keysRemoved: number;
	tokensRedacted: number;
	deepValuesDropped: number;
}

function newStats(): FilterStats {
	return {
		forwarded: 0,
		malformed: 0,
		invalid: 0,
		unknownType: 0,
		oversize: 0,
		unterminated: 0,
		keysRemoved: 0,
		tokensRedacted: 0,
		deepValuesDropped: 0
	};
}

/**
 * A TransformStream from an agent's SSE bytes to the sanitised SSE bytes the
 * browser receives. `label` names the route in the server log line.
 *
 * Parsing follows the SSE spec: lines end in LF, CRLF or CR; `data:` lines of
 * one event are joined with "\n"; a blank line ends the event; an event still
 * open when the stream ends is discarded. Only `data` is used. `event:`, `id:`
 * and `retry:` lines are ignored, and comment text is never forwarded — an
 * event made only of comments is re-emitted as a bare ":" keep-alive so a
 * heartbeat still keeps idle proxies from closing the connection.
 */
export function createActivityFilter(label: string): TransformStream<Uint8Array, Uint8Array> {
	const decoder = new TextDecoder('utf-8');
	const encoder = new TextEncoder();
	const lineBreak = /\r\n|\r|\n/g;
	const stats = newStats();

	let pending = ''; // text after the last line break, not yet a full line
	let dataLines: string[] = [];
	let dataChars = 0;
	let sawComment = false;
	let discardingEvent = false; // current event overflowed: skip it up to its blank line
	let discardingLine = false; // an overlong line was cut: its tail is not a blank line

	function resetEvent(): void {
		dataLines = [];
		dataChars = 0;
		sawComment = false;
		discardingEvent = false;
	}

	function overflow(): void {
		if (!discardingEvent) stats.oversize++;
		dataLines = [];
		dataChars = 0;
		discardingEvent = true;
	}

	function emit(data: string, controller: TransformStreamDefaultController<Uint8Array>): void {
		let event: StreamEvent | null;
		try {
			event = sanitizeEvent(JSON.parse(data), stats);
		} catch {
			// Not JSON (or it could not be sanitised): dropped, never passed through.
			stats.malformed++;
			return;
		}
		if (!event) return;
		controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
		stats.forwarded++;
	}

	function onLine(line: string, controller: TransformStreamDefaultController<Uint8Array>): void {
		if (discardingLine) {
			discardingLine = false;
			return;
		}
		if (line === '') {
			if (!discardingEvent) {
				if (dataLines.length > 0) emit(dataLines.join('\n'), controller);
				else if (sawComment) controller.enqueue(encoder.encode(':\n\n'));
			}
			resetEvent();
			return;
		}
		if (discardingEvent) return;
		if (line.startsWith(':')) {
			sawComment = true;
			return;
		}
		const colon = line.indexOf(':');
		const field = colon === -1 ? line : line.slice(0, colon);
		if (field !== 'data') return;
		let value = colon === -1 ? '' : line.slice(colon + 1);
		if (value.startsWith(' ')) value = value.slice(1);
		dataChars += value.length;
		if (dataChars > MAX_EVENT_CHARS) {
			overflow();
			return;
		}
		dataLines.push(value);
	}

	/**
	 * Hands every complete line in `pending` to onLine. After each drain,
	 * `pending` holds no line break except possibly one held CR at its end, so
	 * scanning resumes at `scanFrom` (that CR, or the new text) instead of
	 * re-reading the whole pending line on every chunk.
	 */
	function drain(controller: TransformStreamDefaultController<Uint8Array>, scanFrom: number, final: boolean): void {
		let start = 0;
		lineBreak.lastIndex = scanFrom;
		for (let match = lineBreak.exec(pending); match !== null; match = lineBreak.exec(pending)) {
			// A CR as the very last character may be the first half of a CRLF
			// split across chunks: wait for the next chunk before deciding.
			if (match[0] === '\r' && match.index === pending.length - 1 && !final) break;
			onLine(pending.slice(start, match.index), controller);
			start = match.index + match[0].length;
		}
		pending = pending.slice(start);
		if (pending.length > MAX_EVENT_CHARS) {
			pending = '';
			discardingLine = true;
			overflow();
		}
	}

	return new TransformStream<Uint8Array, Uint8Array>({
		transform(chunk, controller) {
			const scanFrom = Math.max(0, pending.length - 1);
			pending += decoder.decode(chunk, { stream: true });
			drain(controller, scanFrom, false);
		},
		flush(controller) {
			const scanFrom = Math.max(0, pending.length - 1);
			pending += decoder.decode();
			drain(controller, scanFrom, true);
			// Per the SSE spec an event with no closing blank line is discarded.
			if (pending !== '' || dataLines.length > 0) stats.unterminated++;
			const dropped = stats.malformed + stats.invalid + stats.unknownType + stats.oversize + stats.unterminated;
			if (dropped > 0 || stats.keysRemoved > 0 || stats.tokensRedacted > 0 || stats.deepValuesDropped > 0) {
				// Counts only: an agent's content, even a dropped type's name, is never logged.
				console.warn(
					`[activity-filter] ${label}: forwarded=${stats.forwarded} dropped=${dropped}` +
						` (malformed=${stats.malformed} invalid=${stats.invalid} unknown_type=${stats.unknownType}` +
						` oversize=${stats.oversize} unterminated=${stats.unterminated})` +
						` keys_removed=${stats.keysRemoved} tokens_redacted=${stats.tokensRedacted}` +
						` deep_values_dropped=${stats.deepValuesDropped}`
				);
			}
		}
	});
}

/**
 * The Response a route returns for an agent's SSE body: the body piped through
 * the activity filter, with headers that stop proxies from buffering it.
 */
export function filteredEventStream(upstream: ReadableStream<Uint8Array>, label: string): Response {
	return new Response(upstream.pipeThrough(createActivityFilter(label)), {
		headers: {
			'Content-Type': 'text/event-stream',
			'Cache-Control': 'no-cache',
			Connection: 'keep-alive',
			'X-Accel-Buffering': 'no'
		}
	});
}
