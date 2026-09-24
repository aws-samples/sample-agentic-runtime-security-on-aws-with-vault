/**
 * agent-proxy.ts — the limits on every call the UI server makes to an agent.
 *
 * The browser leaves: the call to the agent is closed at once, so an agent
 * does not keep working, and holding credentials, for an answer nobody will
 * read.
 *
 * A route creates one AgentCall per request, passes `call.signal` to fetch(),
 * and reads the agent's body only through `call.readText()` or
 * `streamAgentEvents()`. Both end the call, so its listeners never outlive the
 * request.
 *
 * Why not request.signal alone: SvelteKit aborts request.signal only when the
 * browser leaves before its request body has been read, and Node's request
 * 'close' event fires as soon as that body is read, while the browser is still
 * waiting. The socket's 'close' event is what marks the browser leaving. Under
 * `vite dev` there is no `platform`, so only request.signal is watched there.
 */

import { createActivityFilter } from '$lib/server/activity-filter';

export type AgentCallStop = 'browser_left';

export class AgentCall {
	/** Pass to fetch(). Aborts when the browser leaves. */
	readonly signal: AbortSignal;
	readonly #controller = new AbortController();
	readonly #unwatch: Array<() => void> = [];
	#stopped: AgentCallStop | null = null;
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
	}

	/** Why the call was stopped, or null while it was not. */
	get stopped(): AgentCallStop | null {
		return this.#stopped;
	}

	/** The call is over, however it ended: stop watching the browser. */
	end(): void {
		if (this.#ended) return;
		this.#ended = true;
		for (const unwatch of this.#unwatch.splice(0)) unwatch();
	}

	#stop(reason: AgentCallStop): void {
		if (this.#ended) return;
		this.#stopped = reason;
		this.end();
		this.#controller.abort(new Error('the browser closed the request'));
	}

	/**
	 * Reads the agent's whole body as text and ends the call. Rejects when the
	 * call is stopped or the agent drops the connection part-way.
	 */
	async readText(res: Response): Promise<string> {
		try {
			return await res.text();
		} finally {
			this.end();
		}
	}

	/** The agent's body. The call ends with it. */
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
 * The Response a route returns for an agent's event stream: the body piped
 * through the activity filter, with headers that stop proxies from buffering
 * it.
 */
export function streamAgentEvents(call: AgentCall, body: ReadableStream<Uint8Array>, label: string): Response {
	return new Response(call.watch(body).pipeThrough(createActivityFilter(label)), {
		headers: {
			'Content-Type': 'text/event-stream',
			'Cache-Control': 'no-cache',
			Connection: 'keep-alive',
			'X-Accel-Buffering': 'no'
		}
	});
}
