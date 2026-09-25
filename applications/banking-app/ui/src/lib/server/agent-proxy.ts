/**
 * agent-proxy.ts — the limits on every call the UI server makes to an agent.
 *
 * 1. The browser leaves: the call to the agent is closed at once, so an agent
 *    does not keep working, and holding credentials, for an answer nobody
 *    will read.
 * 2. The agent goes quiet: when no byte arrives from the agent for
 *    AGENT_IDLE_TIMEOUT_SECONDS, the call is closed and the browser is told —
 *    a JSON 504 when the answer had not started, or the legacy `error` frame
 *    followed by `end` when an event stream had.
 *
 * A route creates one AgentCall per request, passes `call.signal` to fetch(),
 * calls `call.touch()` when the agent's headers arrive, and reads the agent's
 * body only through `call.readText()` or
 * `streamAgentEvents()`. Both end the call, so its listeners and timer never
 * outlive the request.
 *
 * Why not request.signal alone: SvelteKit aborts request.signal only when the
 * browser leaves before its request body has been read, and Node's request
 * 'close' event fires as soon as that body is read, while the browser is still
 * waiting. The socket's 'close' event is what marks the browser leaving. Under
 * `vite dev` there is no `platform`, so only request.signal is watched there.
 */

import { json } from '@sveltejs/kit';
import type { LegacyEndEvent, LegacyErrorEvent } from '$lib/agent-events';
import { createActivityFilter } from '$lib/server/activity-filter';

/**
 * Longest the UI server waits for the next byte from an agent (headers count).
 * It must be longer than the longest silence of an agent that is still
 * working: Use Case 3 waiting for the user's phone approval, in
 * applications/uc3-agent/app/agent.py `_poll_ciba`. It polls for up to
 * CIBA_TIMEOUT_SECONDS = 120 without sending anything; its last poll can start
 * just before that deadline and wait on its httpx client's timeout=30.0, and a
 * slow_down answer adds a back-off of CIBA_POLL_INTERVAL_SECONDS * 2 = 10 s.
 * (Lines 149, 283 and 322 of agent.py when this was written.) That is a
 * realistic worst case of 160 s of silence — not a hard ceiling, since httpx
 * applies its 30 s to each phase of a request separately — plus a 30 s margin.
 */
export const AGENT_IDLE_TIMEOUT_SECONDS = 120 + 30 + 10 + 30;

export type AgentCallStop = 'browser_left' | 'agent_idle';

export class AgentCall {
	/** Pass to fetch(). Aborts when the browser leaves or the agent goes quiet. */
	readonly signal: AbortSignal;
	readonly #controller = new AbortController();
	readonly #unwatch: Array<() => void> = [];
	#stopped: AgentCallStop | null = null;
	#timer: ReturnType<typeof setTimeout> | undefined;
	#ended = false;

	constructor(request: Request, platform: App.Platform | undefined) {
		this.signal = this.#controller.signal;
		const browserLeft = () => this.#stop('browser_left');

		if (request.signal.aborted) {
			browserLeft();
			return;
		}
		request.signal.addEventListener('abort', browserLeft, { once: true });
		this.#unwatch.push(() => request.signal.removeEventListener('abort', browserLeft));

		const socket = platform?.req.socket;
		if (socket) {
			if (socket.destroyed) {
				browserLeft();
				return;
			}
			socket.once('close', browserLeft);
			this.#unwatch.push(() => socket.off('close', browserLeft));
		}
		this.touch();
	}

	/** Why the call was stopped, or null while it was not. */
	get stopped(): AgentCallStop | null {
		return this.#stopped;
	}

	/** The agent just sent something (its headers or a body chunk): restart the idle clock. */
	touch(): void {
		if (this.#ended) return;
		clearTimeout(this.#timer);
		this.#timer = setTimeout(() => this.#stop('agent_idle'), AGENT_IDLE_TIMEOUT_SECONDS * 1000);
	}

	/** The call is over, however it ended: stop watching the browser and the clock. */
	end(): void {
		if (this.#ended) return;
		this.#ended = true;
		clearTimeout(this.#timer);
		for (const unwatch of this.#unwatch.splice(0)) unwatch();
	}

	#stop(reason: AgentCallStop): void {
		if (this.#ended) return;
		this.#stopped = reason;
		this.end();
		this.#controller.abort(
			new Error(
				reason === 'agent_idle'
					? `the agent sent nothing for ${AGENT_IDLE_TIMEOUT_SECONDS} s`
					: 'the browser closed the request'
			)
		);
	}

	/**
	 * Reads the agent's whole body as text, restarting the idle clock on every
	 * chunk, and ends the call. Rejects when the call is stopped or the agent
	 * drops the connection part-way.
	 */
	async readText(res: Response): Promise<string> {
		try {
			if (!res.body) return '';
			const reader = res.body.getReader();
			const decoder = new TextDecoder('utf-8');
			let text = '';
			for (;;) {
				const { value, done } = await reader.read();
				if (done) return text + decoder.decode();
				this.touch();
				text += decoder.decode(value, { stream: true });
			}
		} finally {
			this.end();
		}
	}

	/** The agent's body with the idle clock restarted on every chunk. The call ends with it. */
	watch(body: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
		const reader = body.getReader();
		return new ReadableStream<Uint8Array>({
			pull: async (controller) => {
				let chunk: ReadableStreamReadResult<Uint8Array>;
				try {
					chunk = await reader.read();
				} catch (err) {
					this.end();
					controller.error(err);
					return;
				}
				if (chunk.done) {
					this.end();
					controller.close();
					return;
				}
				this.touch();
				controller.enqueue(chunk.value);
			},
			cancel: (reason) => {
				this.end();
				return reader.cancel(reason);
			}
		});
	}
}

/**
 * The JSON answer for a call that failed before any of the agent's answer
 * reached the browser: 504 when the agent went quiet, otherwise 502 with what
 * went wrong. `agentName` names the agent for the person reading it.
 */
export function agentFailed(call: AgentCall, agentName: string, detail: string): Response {
	if (call.stopped === 'agent_idle') {
		return json(
			{ error: `The ${agentName} agent sent nothing for ${AGENT_IDLE_TIMEOUT_SECONDS} seconds, so the request was stopped.` },
			{ status: 504 }
		);
	}
	return json({ error: detail }, { status: 502 });
}

function sseFrame(event: LegacyErrorEvent | LegacyEndEvent): string {
	return `data: ${JSON.stringify(event)}\n\n`;
}

/**
 * The Response a route returns for an agent's event stream: the body piped
 * through the activity filter, with headers that stop proxies from buffering
 * it. If the agent goes quiet part-way, the browser gets the legacy `error`
 * frame and then `end`, so the chat unlocks and says why.
 */
export function streamAgentEvents(
	call: AgentCall,
	body: ReadableStream<Uint8Array>,
	label: string,
	agentName: string
): Response {
	const filtered = call.watch(body).pipeThrough(createActivityFilter(label)).getReader();
	const encoder = new TextEncoder();
	const stream = new ReadableStream<Uint8Array>({
		async pull(controller) {
			try {
				const { value, done } = await filtered.read();
				if (done) controller.close();
				else controller.enqueue(value);
			} catch (err) {
				if (call.stopped !== 'agent_idle') {
					controller.error(err);
					return;
				}
				const content = `The ${agentName} agent sent nothing for ${AGENT_IDLE_TIMEOUT_SECONDS} seconds, so its answer was stopped.`;
				controller.enqueue(encoder.encode(sseFrame({ type: 'error', content }) + sseFrame({ type: 'end' })));
				controller.close();
			}
		},
		cancel(reason) {
			return filtered.cancel(reason);
		}
	});
	return new Response(stream, {
		headers: {
			'Content-Type': 'text/event-stream',
			'Cache-Control': 'no-cache',
			Connection: 'keep-alive',
			'X-Accel-Buffering': 'no'
		}
	});
}
