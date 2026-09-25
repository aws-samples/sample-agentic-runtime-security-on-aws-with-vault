/**
 * turn-events.svelte.ts — every agent event of every chat turn, kept per turn.
 *
 * One chat page holds one TurnLog. Each question the visitor sends begins a Turn,
 * and every agent event the stream carries for it (see $lib/agent-events) is
 * pushed onto that Turn, in arrival order, unchanged. The Agent Log, the Security
 * Flow and the Audit Trace all read the same Turns:
 *
 *   const log = createTurnLog();
 *   const turn = log.begin(question);                 // when the question is sent
 *   sendChatMessage(..., (e) => log.push(e, turn));   // each agent event
 *   log.end(turn);                                    // when its stream is over
 *
 * `push` and `end` take the Turn they belong to, so a late frame from a finished
 * stream can never land in a newer Turn. Without one they act on the latest Turn.
 *
 * `turns` is reactive state: read it in a component or a $derived and the reader
 * updates as events arrive. It is only ever appended to, never replaced.
 */

import type { AgentEvent } from '$lib/agent-events';

export interface Turn {
	/** Unique within the page. */
	id: string;
	/** What the visitor asked. */
	question: string;
	/** When the question was sent: milliseconds since the Unix epoch. */
	startedAt: number;
	/** The first requestId any of the turn's events carried: the key to its audit rows. */
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
		}
	};
}
