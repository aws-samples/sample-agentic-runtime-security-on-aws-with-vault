/**
 * activity-filter.ts — the one gate every agent event passes through on its way
 * to the browser.
 *
 * What the browser sees
 * ---------------------
 * The workshop shows, as it happens, what each use case does in the background,
 * so every credential issued during a turn reaches the browser IN FULL: sign-in
 * tokens, the refund tokens, Vault tokens, the Kubernetes service-account JWT,
 * database and AWS credentials. Values are never changed by this filter.
 * Configuration secrets are different: an OAuth client secret, a SCIM, admin or
 * LDAP password, Vault's root token and its unseal or recovery keys must never
 * reach a browser. They are removed by KEY NAME (isConfigSecretKey below).
 *
 * It fails closed: anything it does not recognise is dropped.
 *
 * Two layers
 * ----------
 * 1. Envelope (strict allowlist). Each event type has a fixed list of top-level
 *    fields (SCHEMAS below, checked at compile time against $lib/agent-events).
 *    Unknown event types are dropped. Unknown fields are dropped. A frame
 *    missing a required field, or carrying one of the wrong type, is dropped.
 *
 * 2. Payload keys. Fields that carry arbitrary data — tool `args` and `result`,
 *    HITL `details`, audit `leases` and `claims`, a credential's `claims` and
 *    `fields` — are walked recursively:
 *      - a key that names a configuration secret is removed, however deep it
 *        sits, together with its value;
 *      - __proto__, constructor and prototype keys are removed (PROTOTYPE_KEYS);
 *      - nesting deeper than MAX_PAYLOAD_DEPTH is removed.
 *    The same rules apply to a JSON body that is not a stream (scrubJson) and to
 *    a JSON error body (scrubErrorText).
 *
 * Streaming
 * ---------
 * createActivityFilter() is a TransformStream. It parses Server-Sent Events
 * incrementally: frames split across network chunks are reassembled, each
 * complete frame is sanitised and re-emitted at once, and the body as a whole
 * is never buffered. Pending text is capped (MAX_EVENT_CHARS for an event's
 * data, MAX_LINE_CHARS for one unfinished line) so a frame that never ends
 * cannot grow memory without bound.
 *
 * What it does NOT catch: a configuration secret written as free text, such as
 * narration that says "the client secret is ..." or an error body that is not
 * JSON. Keys are matched by name; text is not interpreted. Keeping those values
 * out of what an agent writes is the agent's job; this filter is the second line.
 */

import {
	CREDENTIAL_ISSUERS,
	CREDENTIAL_KINDS,
	NARRATION_GLYPHS,
	TOOL_CALL_STATUSES,
	type JsonValue,
	type StreamEvent,
	type StreamEventType
} from '$lib/agent-events';

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

/** Largest event data the parser accepts: the `data` of all of one event's lines together. */
const MAX_EVENT_CHARS = 1024 * 1024;
/**
 * Longest line the parser holds while waiting for its line break: a data value
 * of MAX_EVENT_CHARS, plus its `data: ` field prefix, plus a CR held back in
 * case it is the first half of a CRLF. Measured against the whole line, so a
 * frame that is within MAX_EVENT_CHARS passes however the network splits it.
 */
const MAX_LINE_CHARS = MAX_EVENT_CHARS + 'data: '.length + 1;
/** Deepest payload nesting kept. Anything deeper is dropped, not passed through. */
const MAX_PAYLOAD_DEPTH = 32;
/** Longest identifier (requestId, toolCallId, tool name, role) accepted. */
const MAX_ID_CHARS = 256;

// ---------------------------------------------------------------------------
// Key rules for payload data
// ---------------------------------------------------------------------------

/**
 * True when a key names a configuration secret. The key is lowercased with
 * every non-alphanumeric removed first, so client_secret, clientSecret and
 * IVIA_CLIENT_SECRET all contain "clientsecret". The rules cover the names this
 * repository gives those secrets:
 *   - OAuth client secrets: client_secret, clientSecret, IVIA_CLIENT_SECRET,
 *     IVIA_ACTOR_CLIENT_SECRET, ivia_mmfa_push_client_secret;
 *   - SCIM, admin and LDAP passwords: IVIA_SCIM_PASSWORD, ivia_scim_bind_pwd,
 *     admin_password, admin_pass, ADMIN_PWD, LDAP_ADMIN_PASSWORD,
 *     openldap_admin_pwd;
 *   - Vault root and unseal material: root_token, VAULT_ROOT_TOKEN,
 *     RECOVERY_KEYS, recovery_keys_b64, the CLI's unseal_keys_b64, and the
 *     keys_base64 of Vault's sys/init reply.
 * Issued credentials are NOT matched: password, username, secret_access_key,
 * session_token, access_token and the like pass.
 */
function isConfigSecretKey(key: string): boolean {
	const k = key.toLowerCase().replace(/[^a-z0-9]/g, '');
	if (k.includes('clientsecret')) return true;
	if ((k.includes('admin') || k.includes('scim') || k.includes('ldap')) && (k.includes('pass') || k.includes('pwd'))) {
		return true;
	}
	return k.includes('roottoken') || k.includes('unsealkey') || k.includes('recoverykey') || k === 'keysbase64';
}

/**
 * Keys that change an object's prototype when browser code merges a payload
 * with Object.assign or a recursive merge. Never forwarded.
 */
const PROTOTYPE_KEYS: ReadonlySet<string> = new Set(['__proto__', 'constructor', 'prototype']);

// ---------------------------------------------------------------------------
// Payload walk
// ---------------------------------------------------------------------------

function isJsonObject(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Returns a copy of `value` without configuration-secret keys, prototype keys
 * or over-deep nesting, or undefined when nothing of it may pass. Strings,
 * numbers and booleans are copied unchanged. The input is only ever read; a new
 * structure is built from what survives.
 */
function scrubValue(value: unknown, depth: number, stats: FilterStats): JsonValue | undefined {
	if (typeof value === 'string' || typeof value === 'boolean' || value === null) return value;
	if (typeof value === 'number') return Number.isFinite(value) ? value : undefined;
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
				stats.prototypeKeysRemoved++;
				continue;
			}
			if (isConfigSecretKey(key)) {
				stats.configKeysRemoved++;
				continue;
			}
			const scrubbed = scrubValue(item, depth + 1, stats);
			if (scrubbed !== undefined) entries.push([key, scrubbed]);
		}
		return Object.fromEntries(entries);
	}
	return undefined;
}

/**
 * Applies the payload key rules to a JSON body that is not a stream, e.g. the
 * Use Case 1 agent's `{ answer, sources, credential_metadata }` reply.
 */
export function scrubJson(value: unknown): JsonValue | undefined {
	return scrubValue(value, 0, newStats());
}

/**
 * Prepares an agent's error body for the user. A JSON body loses its
 * configuration-secret keys; any other body is returned as it is.
 */
export function scrubErrorText(text: string): string {
	let parsed: unknown;
	try {
		parsed = JSON.parse(text);
	} catch {
		return text;
	}
	const scrubbed = scrubValue(parsed, 0, newStats());
	return scrubbed === undefined ? '' : JSON.stringify(scrubbed);
}

// ---------------------------------------------------------------------------
// Envelope allowlist
// ---------------------------------------------------------------------------

type FieldSpec =
	| { kind: 'string'; maxLength?: number }
	| { kind: 'enum'; values: readonly string[] }
	| { kind: 'number'; min?: number }
	/** Any JSON value, walked with the payload key rules. */
	| { kind: 'json' }
	/** A JSON object, walked with the payload key rules. */
	| { kind: 'object' }
	/** An array of JSON objects, walked with the payload key rules; non-object items are dropped. */
	| { kind: 'objectArray' }
	/**
	 * A flat object whose values are all strings, e.g. a credential's `fields`.
	 * Configuration-secret and prototype keys are removed; any other value that
	 * is not a string fails the rule, and so does an object left empty.
	 */
	| { kind: 'stringMap' };

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
	// Issued credentials pass in full. `value` and `fields` are exclusive: see EXACTLY_ONE_OF.
	'agent:credential': {
		...ENVELOPE,
		kind: { kind: 'enum', values: CREDENTIAL_KINDS, required: true },
		label: { kind: 'string', required: true },
		issuer: { kind: 'enum', values: CREDENTIAL_ISSUERS, required: true },
		value: { kind: 'string', required: false },
		fields: { kind: 'stringMap', required: false },
		claims: { kind: 'object', required: false },
		vaultPath: { kind: 'string', maxLength: MAX_ID_CHARS, required: false },
		leaseId: { kind: 'string', maxLength: MAX_ID_CHARS, required: false },
		ttlSeconds: { kind: 'number', min: 0, required: false },
		expiresAt: { kind: 'number', min: 0, required: false }
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
			return rule.maxLength !== undefined && value.length > rule.maxLength ? undefined : value;
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
		case 'stringMap': {
			if (!isJsonObject(value)) return undefined;
			const entries: [string, string][] = [];
			for (const [key, item] of Object.entries(value)) {
				if (PROTOTYPE_KEYS.has(key)) {
					stats.prototypeKeysRemoved++;
					continue;
				}
				if (isConfigSecretKey(key)) {
					stats.configKeysRemoved++;
					continue;
				}
				if (typeof item !== 'string') return undefined;
				entries.push([key, item]);
			}
			return entries.length > 0 ? Object.fromEntries(entries) : undefined;
		}
	}
}

/**
 * Event types whose frame must carry exactly one of two fields, and keep it
 * after sanitising. A frame with both, with neither, or whose one field fails
 * its rule is dropped.
 */
const EXACTLY_ONE_OF: ReadonlyMap<string, readonly [string, string]> = new Map([
	['agent:credential', ['value', 'fields'] as const]
]);

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
	const exclusive = EXACTLY_ONE_OF.get(parsed.type);
	if (exclusive && Object.hasOwn(parsed, exclusive[0]) === Object.hasOwn(parsed, exclusive[1])) {
		stats.invalid++;
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
	if (exclusive && !Object.hasOwn(event, exclusive[0]) && !Object.hasOwn(event, exclusive[1])) {
		stats.invalid++;
		return null;
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
	configKeysRemoved: number;
	prototypeKeysRemoved: number;
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
		configKeysRemoved: 0,
		prototypeKeysRemoved: 0,
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
		if (pending.length > MAX_LINE_CHARS) {
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
			const removed = stats.configKeysRemoved + stats.prototypeKeysRemoved + stats.deepValuesDropped;
			if (dropped > 0 || removed > 0) {
				// Counts only: an agent's content, even a dropped type's name, is never logged.
				console.warn(
					`[activity-filter] ${label}: forwarded=${stats.forwarded} dropped=${dropped}` +
						` (malformed=${stats.malformed} invalid=${stats.invalid} unknown_type=${stats.unknownType}` +
						` oversize=${stats.oversize} unterminated=${stats.unterminated})` +
						` config_secret_keys_removed=${stats.configKeysRemoved}` +
						` prototype_keys_removed=${stats.prototypeKeysRemoved}` +
						` deep_values_dropped=${stats.deepValuesDropped}`
				);
			}
		}
	});
}
