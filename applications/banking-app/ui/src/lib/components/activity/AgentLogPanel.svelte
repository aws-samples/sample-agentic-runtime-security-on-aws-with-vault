<!--
  AgentLogPanel — the Agent Log: a dark terminal panel beside a chat that prints, line by line
  as it arrives, every step the agent takes in each turn — model calls, tool calls and their
  output, Vault logins and every credential in full, with a Copy button.

  The page owns the turns (createTurnLog() in $lib/turn-events.svelte) and passes them in; the
  lines come from logLines() in $lib/agent-log. Rendered in ChatWorkspace's `panel` slot:

    {#snippet panel()}
      {#if openPanel === 'log'}
        <AgentLogPanel id="agent-log" turns={log.turns} systems="IVIA · Vault · MCP" onclose={...} />
      {/if}
    {/snippet}

  `id` must match the Agent log button's aria-controls: closing the panel (the X or Escape)
  returns focus to that button. `systems` is the footer's list of the systems the chat uses.

  Each question is one fold. Its header is a button that shows when the question was asked,
  the question on one line, its state (● running, ✓ finished, ✕ failed) and how many entries
  it holds; clicking it opens or closes that request's lines. A new question opens its own
  fold and closes every earlier one; several folds can be open at once after that. Folded
  lines are not drawn, but nothing is lost: what a line had expanded ("Show all") is kept,
  and a credential's Copy works again as soon as its fold is open. The footer counts
  requests and entries.

  Wider than 960px the panel sits beside the chat, 420px wide, or 520px while the left
  navigation is collapsed to its rail (ChatWorkspace sets --ovi-panel-width). At 960px and
  narrower it covers the chat from the right, under the top bar, and the navigation drawer
  opens over it.
-->
<script lang="ts">
	import { tick, untrack } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';
	import { clockTime, logLines, turnState, type TurnState } from '$lib/agent-log';
	import type { Turn } from '$lib/turn-events.svelte';

	interface Props {
		id: string;
		turns: readonly Turn[];
		/** Footer text, e.g. "Kubernetes auth · Vault · Bedrock". */
		systems: string;
		onclose: () => void;
	}

	let { id, turns, systems, onclose }: Props = $props();

	/** Tool output longer than this is cut, with "Show all" to see the rest. */
	const OUTPUT_PREVIEW_CHARS = 600;

	/** The glyph a fold's header shows for each state. A screen reader hears the state's name. */
	const STATE_GLYPH: Record<TurnState, string> = { running: '●', finished: '✓', failed: '✕' };

	const view = $derived(
		turns.map((turn) => ({
			id: turn.id,
			question: turn.question,
			time: clockTime(turn.startedAt),
			state: turnState(turn),
			lines: logLines(turn)
		}))
	);
	const entries = $derived(view.reduce((sum, turn) => sum + turn.lines.length, 0));
	const live = $derived(turns.length > 0 && !turns[turns.length - 1].done);

	const expanded = new SvelteSet<string>();
	let copied = $state<string | null>(null);
	let announcement = $state('');

	// Which folds are open. The choice is kept with the latest turn it was made for: once a
	// newer question exists it no longer applies, and only that newest fold is open. So a new
	// question folds every earlier request, and the panel opens with only the latest one open.
	const latestId = $derived(turns.at(-1)?.id);
	let folds = $state<{ latest: string | undefined; open: string[] }>({ latest: undefined, open: [] });
	const openFolds = $derived(
		folds.latest === latestId ? folds.open : latestId === undefined ? [] : [latestId]
	);

	async function toggleFold(turnId: string) {
		const open = openFolds.includes(turnId) ? openFolds.filter((id) => id !== turnId) : [...openFolds, turnId];
		folds = { latest: latestId, open };
		// Opening or closing a fold moves the tail without a scroll event: measure again, so
		// a request opened above the tail is not scrolled away when the next line arrives.
		await tick();
		onScroll();
	}

	// Follow new lines, unless the reader has scrolled up to read an earlier one. A new
	// question is followed again: its fold is the one that just opened.
	let bodyEl: HTMLDivElement | undefined = $state();
	let followTail = true;
	let followedTurn: string | undefined;
	function onScroll() {
		if (bodyEl) followTail = bodyEl.scrollHeight - bodyEl.scrollTop - bodyEl.clientHeight < 32;
	}
	$effect(() => {
		void entries;
		const latest = latestId;
		if (latest !== followedTurn) {
			followedTurn = latest;
			followTail = true;
		}
		if (bodyEl && followTail) bodyEl.scrollTop = bodyEl.scrollHeight;
	});

	// The log itself is not announced line by line (role="log" with aria-live="off"): a turn
	// prints dozens of lines. A screen reader hears one status line when a turn ends.
	let wasLive = false;
	$effect(() => {
		const now = live;
		if (wasLive && !now) {
			const count = untrack(() => entries);
			announcement = `Agent activity finished: ${count} ${count === 1 ? 'entry' : 'entries'}.`;
		}
		wasLive = now;
	});

	async function close() {
		const toggle = document.querySelector<HTMLElement>(`[aria-controls="${id}"]`);
		onclose();
		await tick();
		toggle?.focus();
	}

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'Escape') {
			event.stopPropagation();
			close();
		}
	}

	async function copy(key: string, text: string, what: string) {
		try {
			await navigator.clipboard.writeText(text);
			copied = key;
			announcement = `${what} copied.`;
			setTimeout(() => {
				if (copied === key) copied = null;
			}, 1500);
		} catch {
			copied = null;
			announcement = `Could not copy the ${what}: this browser blocked clipboard access.`;
		}
	}

	function toggleExpanded(key: string) {
		if (expanded.has(key)) expanded.delete(key);
		else expanded.add(key);
	}
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<aside {id} class="agent-log" aria-labelledby="{id}-title" onkeydown={onKeydown}>
	<header class="log-header">
		<h2 id="{id}-title" class="log-title">Agent activity</h2>
		<span class="live-dot" class:live-dot-idle={!live} role="img" aria-label={live ? 'Streaming' : 'Idle'}></span>
		<button type="button" class="log-close" aria-label="Close agent activity" onclick={close}>
			<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
				<path d="M4 4l10 10M14 4L4 14"></path>
			</svg>
		</button>
	</header>

	<!-- tabindex makes the scrolling region reachable for keyboard scrolling. -->
	<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
	<div
		class="log-body"
		bind:this={bodyEl}
		onscroll={onScroll}
		role="log"
		aria-live="off"
		aria-label="Agent activity lines"
		tabindex="0"
	>
		{#if view.length === 0}
			<p class="log-empty">No activity yet. Ask a question and every step the agent takes appears here.</p>
		{/if}

		{#each view as turn (turn.id)}
			{@const foldOpen = openFolds.includes(turn.id)}
			<div class="rq">
				<button type="button" class="rqh" aria-expanded={foldOpen} onclick={() => toggleFold(turn.id)}>
					<span class="chev" aria-hidden="true">{foldOpen ? '▾' : '▸'}</span>
					<span class="rqt">{turn.time}</span>
					<span class="rqq">{turn.question}</span>
					<span class="rqs">
						<span
							class:st-run={turn.state === 'running'}
							class:st-ok={turn.state === 'finished'}
							class:st-bad={turn.state === 'failed'}
							aria-hidden="true">{STATE_GLYPH[turn.state]}</span
						><span class="visually-hidden">{turn.state},</span> {turn.lines.length} {turn.lines.length === 1 ? 'entry' : 'entries'}
					</span>
				</button>
				{#if foldOpen}
					<div class="rqb">
						{#if turn.lines.length === 0 && turn.state === 'running'}
							<p class="log-empty">Waiting for the agent…</p>
						{/if}
						{#each turn.lines as line, lineIndex (lineIndex)}
							{@const key = `${turn.id}:${lineIndex}`}
							{#if line.kind === 'step'}
								<div class="ln">
									<span class="glyph-step" aria-hidden="true">▶</span>
									<span><span class="lb">Agent:</span> {line.text}</span>
								</div>
							{:else if line.kind === 'output' || line.kind === 'error'}
								{@const long = line.text.length > OUTPUT_PREVIEW_CHARS}
								{@const open = expanded.has(key)}
								<div class="ln">
									{#if line.kind === 'error'}
										<span class="glyph-error" aria-hidden="true">✕</span>
									{:else}
										<span class="glyph-out" aria-hidden="true">⚡&#xFE0E;</span>
									{/if}
									<span class="out" class:out-error={line.kind === 'error'}>
										<span class="lb">{line.label}</span>{long && !open ? `${line.text.slice(0, OUTPUT_PREVIEW_CHARS)}…` : line.text}
										{#if long}
											<button type="button" class="chip-button" aria-expanded={open} onclick={() => toggleExpanded(key)}>
												{open ? 'Show less' : `Show all ${line.text.length} characters`}
											</button>
										{/if}
									</span>
								</div>
							{:else}
								{@const c = line.credential}
								<div class="ln">
									<span class="glyph-out" aria-hidden="true">⚡&#xFE0E;</span>
									<span class="out">
										<span class="lb">Credential {c.verb} · {c.kindLabel}:</span> {[c.source, c.label].filter((part) => part !== '').join(' · ')}
										{#if c.copyText !== undefined}
											{@const copyText = c.copyText}
											<button
												type="button"
												class="chip-button"
												aria-label="Copy the {c.kindLabel}"
												onclick={() => copy(key, copyText, c.kindLabel)}
											>
												{copied === key ? 'Copied' : 'Copy'}
											</button>
										{/if}
										<span class="cred">
											{#if c.value !== undefined}
												<span class="cred-value">{c.value}</span>
											{:else if c.fields}
												<span class="cred-value">
													{#each c.fields as [name, part], partIndex (name)}
														{#if partIndex > 0}{' '}{/if}<span class="cred-part"><span class="cred-key">{name}</span> {part}</span>
													{/each}
												</span>
											{/if}
											{#if c.meta.length > 0}
												<span class="cred-meta">{c.meta.join(' · ')}</span>
											{/if}
										</span>
									</span>
								</div>
							{/if}
						{/each}
					</div>
				{/if}
			</div>
		{/each}
	</div>

	<footer class="log-footer">
		<span>{view.length} {view.length === 1 ? 'request' : 'requests'} · {entries} {entries === 1 ? 'entry' : 'entries'}</span>
		<i>{systems}</i>
	</footer>
	<p class="visually-hidden" role="status">{announcement}</p>
</aside>

<style>
	/* The design's terminal palette, kept on the panel so it cannot leak into the light UI.
	   --log-faint is the design's #64748b: the close icon, the idle dot and the footer text. */
	.agent-log {
		--log-bg: #0f172a;
		--log-line: #334155;
		--log-title: #cbd5e1;
		--log-text: #e2e8f0;
		--log-muted: #94a3b8;
		--log-faint: #64748b;
		--log-step: #38bdf8;
		--log-out-glyph: #fbbf24;
		--log-label: #fb7185;
		--log-out: rgba(253, 230, 138, 0.9);
		--log-key: #67e8f9;
		--log-live: #34d399;

		width: var(--ovi-panel-width, 420px);
		flex-shrink: 0;
		min-height: 0;
		display: flex;
		flex-direction: column;
		background: var(--log-bg);
		border-left: 1px solid var(--log-line);
		letter-spacing: normal;
	}

	.log-header {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 16px 20px;
		border-bottom: 1px solid var(--log-line);
	}

	.log-title {
		flex: 1;
		margin: 0;
		font: 600 12px var(--ovi-font-sans);
		letter-spacing: 0.12em;
		text-transform: uppercase;
		color: var(--log-title);
	}

	.live-dot {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--log-live);
	}

	.live-dot-idle {
		background: var(--log-faint);
	}

	.log-close {
		display: flex;
		padding: 0;
		border: 0;
		background: none;
		color: var(--log-faint);
		cursor: pointer;
	}

	.log-close:hover {
		color: var(--log-title);
	}

	.log-close:focus-visible,
	.rqh:focus-visible,
	.chip-button:focus-visible {
		outline: 2px solid var(--log-step);
		outline-offset: 2px;
	}

	.log-body {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		padding: 12px 16px;
		font: 12.5px/1.65 var(--ovi-font-mono);
		color: var(--log-text);
		/* The screen-reader-only labels are positioned against the log, not the page. */
		position: relative;
	}

	.log-body:focus-visible {
		outline: 2px solid var(--log-step);
		outline-offset: -2px;
	}

	.log-empty {
		margin: 0;
		color: var(--log-muted);
	}

	/* One fold per request: a rule between folds, the header on one line, the lines indented. */
	.rq {
		border-top: 1px solid var(--log-line);
	}

	.rq:first-child {
		border-top: 0;
	}

	.rqh {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		padding: 10px 0;
		border: 0;
		background: none;
		color: var(--log-title);
		font: 12px var(--ovi-font-mono);
		text-align: left;
		cursor: pointer;
	}

	.rqh:hover .rqq {
		color: #fff;
	}

	.chev {
		display: inline-block;
		flex-shrink: 0;
		width: 12px;
		color: var(--log-faint);
	}

	.rqt {
		flex-shrink: 0;
		color: var(--log-faint);
	}

	.rqq {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		color: var(--log-text);
		font: 500 13px var(--ovi-font-sans);
		white-space: nowrap;
		text-overflow: ellipsis;
	}

	.rqs {
		flex-shrink: 0;
		color: var(--log-faint);
		font-size: 11.5px;
		white-space: nowrap;
	}

	.st-ok {
		color: var(--log-live);
	}

	.st-bad {
		color: var(--log-label);
	}

	.st-run {
		color: var(--log-step);
	}

	.rqb {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 0 0 10px 22px;
	}

	.ln {
		display: flex;
		gap: 10px;
		padding: 3px 0;
		min-width: 0;
	}

	.ln > span:last-child {
		min-width: 0;
		overflow-wrap: anywhere;
	}

	.glyph-step {
		flex-shrink: 0;
		color: var(--log-step);
	}

	.glyph-out {
		flex-shrink: 0;
		color: var(--log-out-glyph);
	}

	.glyph-error {
		flex-shrink: 0;
		color: var(--log-label);
	}

	.lb {
		color: var(--log-label);
	}

	.out {
		color: var(--log-out);
		font-size: 11.5px;
		word-break: break-word;
	}

	.out-error {
		color: var(--log-text);
	}

	.chip-button {
		margin-left: 6px;
		padding: 0 6px;
		border: 1px solid var(--log-line);
		border-radius: 999px;
		background: none;
		color: var(--log-muted);
		font: 600 10px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		cursor: pointer;
	}

	.chip-button:hover {
		color: var(--log-title);
		border-color: var(--log-muted);
	}

	.cred {
		display: block;
		margin-top: 3px;
		padding: 6px 8px;
		border: 1px solid var(--log-line);
		border-radius: 8px;
		background: rgba(56, 189, 248, 0.06);
	}

	.cred-value {
		display: block;
		color: var(--log-text);
		word-break: break-all;
	}

	/* The parts run on inline, one after another, as the design shows. The key never breaks
	   mid-word; the value wraps anywhere. */
	.cred-key {
		color: var(--log-key);
		white-space: nowrap;
	}

	.cred-meta {
		display: block;
		color: var(--log-muted);
		font-size: 11px;
	}

	.log-footer {
		display: flex;
		justify-content: space-between;
		gap: 12px;
		padding: 12px 20px;
		border-top: 1px solid var(--log-line);
		font: 12px var(--ovi-font-mono);
		color: var(--log-faint);
	}

	.log-footer i {
		font-family: var(--ovi-font-sans);
		text-align: right;
	}

	/* 960px and narrower: the chat fills the window under the top bar, so the panel covers it
	   from the right. It stays under the navigation drawer and its scrim (z-index 10 and 20). */
	@media (max-width: 960px) {
		.agent-log {
			position: fixed;
			top: var(--ovi-bar-height);
			right: 0;
			bottom: 0;
			z-index: 5;
			width: min(100%, 420px);
			box-sizing: border-box;
			box-shadow: -4px 0 24px rgba(22, 22, 22, 0.28);
		}
	}
</style>
