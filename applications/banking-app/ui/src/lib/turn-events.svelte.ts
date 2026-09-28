/**
 * turn-events.svelte.ts — every agent event of every chat turn, kept per turn.
 *
 * One chat page holds one TurnLog. Each question the visitor sends begins a Turn,
 * and every agent event the stream carries for it (see $lib/agent-events) is
 * pushed onto that Turn, in arrival order, unchanged. The Agent Log, the Security
 * Flow and the Audit Trace all read the same Turns:
 *
 *   const log = createTurnLog();
 *   const turn = log.begin(question);                       // when the question is sent
 *   await sendChatMessage(..., (e) => log.push(e, turn));   // each agent event
 *   if (failure === undefined) log.end(turn);               // when its stream is over,
 *   else log.fail(failure, turn);                           // or when the page showed an error
 *
 * `fail` ends a turn that failed and records that error as one `agent:error` event,
 * so the Agent Log shows the failure, unless the stream already carried an
 * `agent:error` of its own. Call it once the stream is over, never as an error
 * frame arrives: an agent can send its legacy `error` frame before its `agent:error`.
 *
 * `push`, `end` and `fail` take the Turn they belong to, so a late frame from a finished
 * stream can never land in a newer Turn. Without one they act on the latest Turn.
 *
 * `turns` is reactive state: read it in a component or a $derived and the reader
 * updates as events arrive. It is only ever appended to, never replaced.
 */

import type { AgentErrorEvent, AgentEvent } from '$lib/agent-events';

export interface Turn {
	/** Unique within the page. */
	id: string;
	/** What the visitor asked. */
	question: string;
	/** When the question was sent: milliseconds since the Unix epoch. */
	startedAt: number;
	/**
	 * The first requestId any of the turn's events carried. A turn that uses two tools can
	 * carry two, so this is not the key to its audit rows: the Audit Trace keys on the
	 * requestId of the turn's agent:audit_seed event (see $lib/audit-trace).
	 */
	requestId?: string;
	/** Every agent event of the turn, in arrival order. */
	events: AgentEvent[];
	/** True once the turn's stream is over, however it ended. */
	done: boolean;
}

export interface TurnLog {
	/** Every turn of the page, oldest first. */
	readonly turns: Turn[];
	/** Starts a turn for `question` and returns it. */
	begin(question: string): Turn;
	/** Adds one event to `turn` (default: the latest turn). */
	push(event: AgentEvent, turn?: Turn): void;
	/** Marks `turn` (default: the latest turn) as over. */
	end(turn?: Turn): void;
	/**
	 * Marks `turn` (default: the latest turn) as over because it failed, first adding
	 * `{ type: 'agent:error', message }` unless the turn already holds an `agent:error`.
	 */
	fail(message: string, turn?: Turn): void;
}

export function createTurnLog(): TurnLog {
	const turns = $state<Turn[]>([]);
	let sequence = 0;

	return {
		get turns() {
			return turns;
		},
		begin(question: string): Turn {
			sequence += 1;
			turns.push({ id: `turn-${sequence}-${Date.now()}`, question, startedAt: Date.now(), events: [], done: false });
			// The element read back from the state array is its reactive proxy, so
			// changes made through it reach every reader.
			return turns[turns.length - 1];
		},
		push(event: AgentEvent, turn: Turn | undefined = turns.at(-1)): void {
			if (!turn) return;
			if (turn.requestId === undefined && typeof event.requestId === 'string' && event.requestId !== '') {
				turn.requestId = event.requestId;
			}
			turn.events.push(event);
		},
		end(turn: Turn | undefined = turns.at(-1)): void {
			if (turn) turn.done = true;
		},
		fail(message: string, turn: Turn | undefined = turns.at(-1)): void {
			if (!turn) return;
			if (!turn.events.some((event) => event.type === 'agent:error')) {
				const failed: AgentErrorEvent = { type: 'agent:error', message };
				turn.events.push(failed);
			}
			// Added before the turn is marked over: a reader that counts the turn's
			// lines when it ends (the Agent Log's announcement) counts this one too.
			turn.done = true;
		}
	};
}
