<!--
  SecurityFlowPanel — the Security Flow: one chat turn walked through five stops,
  Request → Agent → Authorization → Secure execution → Result.

  Everything on it comes from buildFlow() in $lib/security-flow, which reads only the events
  the turn actually streamed. A stop or signal the stream never reported says "not observed in
  this flow"; nothing is timed or scripted.

    Story      the focus card and "What's happening" in plain English, with the standards the
               current stop uses as chips.
    Technical  adds the sub-step marks on the line, the turn's Technical signals rows with their
               status (observed, not observed in this flow, pending) — for a refund, the approved
               mockup's rows — and the Evidence list: every event of the turn, each with its raw
               payload in full.
    Demo pace  replays the turn from its first event, one event at a time, so a presenter can
               talk over each step. Nothing past the replay point is shown or claimed.
    Live       stops the replay and follows the turn as it streams.

  Props
    id       the panel's element id (the header button's aria-controls).
    useCase  1 Ask page, 2 Banking Agent, 3 Refund Agent.
    turn     the turn to show; undefined before the first question.
    onclose  closes the panel (the close button and Escape). `id` must match the View security
             flow button's aria-controls: closing returns focus to that button.

  Width and landmark follow the ChatWorkspace panel contract: the panel is an <aside> beside the
  chat column, 520px wide on a desktop and full width under the chat on screens 960px and
  narrower.

  Full width: wider than 960px a round expand button before the close button floats the panel
  over the whole window, a modal dialog 24px inside it, with the page behind dimmed and inert
  (ChatWorkspace's float contract). Floating, the controls show "Dock beside chat", and the
  Technical view spreads out as the approved board draws it: the request and a wide five-stop
  line across the top; under them the result card and "What's happening" side by side, the
  Technical signals under both, and the Evidence list in a third column that scrolls on its
  own. The Story view uses the same top row and columns. The first Escape docks the panel and
  returns focus to the expand button; the next one closes it. A click on the scrim docks it.
  Floating and docked are the same component: the view, the replay and opened raw events carry
  over.
-->
<script module lang="ts">
	import type { Turn as LoggedTurn } from '$lib/turn-events.svelte';

	/**
	 * One chat turn, as the page's TurnLog ($lib/turn-events.svelte) holds it. `answer` is
	 * optional and not part of that shape: a refund stream from before the agent sent
	 * agent:text_delta carried its answer only as the legacy `delta` frame, so a page may pass it
	 * here; the flow lists it only when the stream carried no answer of its own.
	 */
	export interface Turn extends LoggedTurn {
		answer?: string;
	}
</script>

<script lang="ts">
	import { onDestroy, tick } from 'svelte';
	import { getPanelFloat } from '$lib/components/chat/ChatWorkspace.svelte';
	import {
		buildFlow,
		chipsUpTo,
		NOT_OBSERVED_TEXT,
		STOP_IDS,
		type EvidenceRow,
		type Flow,
		type Signal,
		type Stop,
		type UseCase
	} from '$lib/security-flow';

	interface Props {
		id: string;
		useCase: UseCase;
		turn: Turn | undefined;
		onclose: () => void;
	}

	let { id, useCase, turn, onclose }: Props = $props();

	/** How long each event stays on screen before the next one appears in a Demo pace replay. */
	const PACE_MS = 1200;

	let mode = $state<'story' | 'technical'>('story');
	let demoPace = $state(false);
	/** Events shown so far in a Demo pace replay. */
	let revealed = $state(0);
	let evidenceOpen = $state(true);
	let rawOpen = $state<Record<number, boolean>>({});
	let replayTurnId: string | undefined;

	// A new turn ends any replay of the previous one.
	$effect(() => {
		const current = turn?.id;
		if (current !== replayTurnId) {
			replayTurnId = current;
			demoPace = false;
			revealed = 0;
			rawOpen = {};
		}
	});

	// Demo pace: reveal the next event every PACE_MS. While the turn is still streaming the
	// replay catches up with it and then waits for the next event.
	$effect(() => {
		if (!demoPace || !turn) return;
		if (revealed >= turn.events.length) return;
		const timer = setTimeout(() => (revealed += 1), PACE_MS);
		return () => clearTimeout(timer);
	});

	let replaying = $derived(demoPace && !!turn && (revealed < turn.events.length || !turn.done));

	let flow = $derived.by((): Flow | undefined => {
		if (!turn) return undefined;
		const events = demoPace ? turn.events.slice(0, revealed) : turn.events;
		const done = demoPace ? turn.done && revealed >= turn.events.length : turn.done;
		return buildFlow(useCase, events, {
			question: turn.question,
			startedAt: turn.startedAt,
			done,
			answer: done ? turn.answer : undefined
		});
	});

	let focus = $derived(flow?.stops.find((s) => s.id === flow?.focus));

	// The Technical view's rows (for a refund, the approved mockup's rows). In a replay a row the
	// replay has not reached yet is left out rather than called pending. A flow that is really
	// waiting (an open approval) still shows what it waits for.
	let signals = $derived(
		(flow?.technical ?? []).filter((s) => !(replaying && s.status === 'pending' && s.tone !== 'waiting'))
	);

	let chips = $derived(
		!flow || !focus ? [] : mode === 'technical' ? chipsUpTo(flow, focus.id) : focus.chips
	);

	function toggleDemoPace() {
		if (demoPace) {
			demoPace = false;
		} else {
			revealed = 0;
			demoPace = true;
		}
	}

	function goLive() {
		demoPace = false;
	}

	// Full width. Without a ChatWorkspace around it the panel stays docked and draws no
	// expand button.
	const float = getPanelFloat();
	let floating = $derived(float?.floating === id);
	let dockButton: HTMLButtonElement | undefined = $state();

	async function expand() {
		float?.expand(id);
		await tick();
		dockButton?.focus();
	}

	// Floating: the page behind is inert, so the float ends before the panel closes and focus
	// can go back to the header button.
	onDestroy(() => float?.release(id));

	/** Closes the panel and returns focus to the header button that opens it. */
	async function close() {
		const toggle = document.querySelector<HTMLElement>(`[aria-controls="${id}"]`);
		float?.release(id);
		onclose();
		await tick();
		toggle?.focus();
	}

	// Escape docks a floating panel (ChatWorkspace returns focus to the expand button) and
	// closes a docked one.
	function onkeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.stopPropagation();
			if (floating) {
				e.preventDefault();
				float?.dock();
			} else {
				close();
			}
		}
	}

	// ---- The line: node positions, segment paths and sub-step marks from the approved boards.
	// Docked, the line is the 468-wide drawing of the Technical board; floating, the 1200-wide
	// drawing of the floating board. Labels sit below each node: `gap` for a small node, `big`
	// for the large focus node, never below `maxY`.
	interface LineGeometry {
		viewBox: string;
		nodes: { x: number; y: number }[];
		segments: string[];
		substeps: string[][];
		gap: number[];
		big: number[];
		maxY: number;
	}
	const DOCKED_LINE: LineGeometry = {
		viewBox: '0 0 468 176',
		nodes: [
			{ x: 30, y: 118 },
			{ x: 135, y: 76 },
			{ x: 240, y: 102 },
			{ x: 345, y: 70 },
			{ x: 440, y: 84 }
		],
		segments: [
			'M30 118 C 70 98, 95 78, 135 76',
			'M135 76 C 175 74, 200 102, 240 102',
			'M240 102 C 280 102, 305 70, 345 70',
			'M345 70 C 385 70, 410 84, 440 84'
		],
		substeps: [
			['M78 92 l6 10', 'M104 80 l4 11'],
			['M170 78 l-3 11', 'M196 88 l-6 9'],
			['M276 96 l6 9', 'M302 80 l5 10'],
			['M384 66 l-1 11', 'M410 72 l-2 11']
		],
		gap: [40, 42, 40, 38, 38],
		big: [58, 58, 58, 58, 56],
		maxY: 172
	};
	const WIDE_LINE: LineGeometry = {
		viewBox: '0 0 1200 150',
		nodes: [
			{ x: 60, y: 96 },
			{ x: 330, y: 54 },
			{ x: 600, y: 80 },
			{ x: 870, y: 48 },
			{ x: 1140, y: 62 }
		],
		segments: [
			'M60 96 C 173 96, 217 54, 330 54',
			'M330 54 C 443 54, 487 80, 600 80',
			'M600 80 C 713 80, 757 48, 870 48',
			'M870 48 C 983 48, 1027 62, 1140 62'
		],
		substeps: [
			['M154.0 79.7 L156.4 90.5', 'M233.6 59.5 L236.0 70.3'],
			['M426.0 55.3 L424.4 66.2', 'M505.6 67.8 L504.0 78.7'],
			['M694.3 66.3 L696.1 77.1', 'M773.9 50.9 L775.7 61.7'],
			['M965.6 46.1 L964.8 57.1', 'M1045.2 52.9 L1044.4 63.9']
		],
		gap: [40, 40, 40, 40, 40],
		big: [58, 58, 58, 58, 56],
		maxY: 146
	};
	let geo = $derived(floating ? WIDE_LINE : DOCKED_LINE);

	type NodeLook = 'done' | 'active' | 'final' | 'failed' | 'not-observed' | 'future';

	function look(stop: Stop, f: Flow): NodeLook {
		const isFocus = stop.id === f.focus;
		if (stop.tone === 'failed') return 'failed';
		if (stop.status === 'observed') return isFocus && f.done ? 'final' : 'done';
		if (isFocus && stop.status === 'pending') return 'active';
		if (stop.status === 'not observed') return 'not-observed';
		return 'future';
	}

	function reached(l: NodeLook): boolean {
		return l === 'done' || l === 'active' || l === 'final' || l === 'failed';
	}

	function labelY(i: number, l: NodeLook): number {
		const big = l === 'active' || l === 'final';
		return Math.min(geo.nodes[i].y + (big ? geo.big[i] : geo.gap[i]), geo.maxY);
	}

	const LOOK_WORDS: Record<NodeLook, string> = {
		done: 'complete',
		final: 'complete',
		active: 'in progress',
		failed: 'stopped',
		'not-observed': NOT_OBSERVED_TEXT,
		future: 'not started'
	};

	function lineLabel(f: Flow, looks: NodeLook[]): string {
		if (looks.every((l) => l === 'done' || l === 'final')) {
			return 'All five stages complete' + (mode === 'technical' ? ', with sub-steps marked between them' : '');
		}
		// The approved mockup reads a stop waiting for approval as "in progress" (Refund board).
		const words = looks.map((l) => LOOK_WORDS[l]);
		const parts: string[] = [];
		let start = 0;
		for (let i = 1; i <= words.length; i++) {
			if (i === words.length || words[i] !== words[start]) {
				const names = f.stops.slice(start, i).map((s) => s.label);
				const joined = names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names.at(-1)}` : names[0];
				parts.push(`${joined} ${words[start]}`);
				start = i;
			}
		}
		return parts.join(', ');
	}

	let looks = $derived(flow ? flow.stops.map((s) => look(s, flow)) : []);

	function statusText(s: Signal): string {
		if (s.status === 'not observed') return NOT_OBSERVED_TEXT;
		return s.note ? `${s.status} · ${s.note}` : s.status;
	}

	function rowTone(r: EvidenceRow): string {
		if (r.status === 'error' || r.status === 'denied') return 'bad';
		if (r.status === 'waiting' || r.status === 'timeout') return 'wait';
		return 'ok';
	}

	let announcement = $derived(
		focus ? `${focus.label}: ${focus.story.eyebrow}. ${focus.story.title}. ${focus.story.line}` : ''
	);
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<aside
	{id}
	class="sf"
	class:floating
	role={floating ? 'dialog' : undefined}
	aria-modal={floating ? 'true' : undefined}
	aria-label={(mode === 'technical' ? 'Live security flow, technical view' : 'Live security flow') + (floating ? ', full width' : '')}
	{onkeydown}
>
	<div class="sf-head">
		<div>
			<div class="eyebrow">Live security flow</div>
			<h2 class="sf-title">See the trust decision unfold</h2>
			<p class="sf-sub">A guided view of the identity, authorization, and agent actions behind this request.</p>
		</div>
		<div class="sf-controls">
			<div class="seg" role="group" aria-label="Detail level">
				<button type="button" class:on={mode === 'story'} aria-pressed={mode === 'story'} onclick={() => (mode = 'story')}>
					Story
				</button>
				<button
					type="button"
					class:on={mode === 'technical'}
					aria-pressed={mode === 'technical'}
					onclick={() => (mode = 'technical')}
				>
					Technical
				</button>
			</div>
			<button type="button" class="pace" aria-pressed={demoPace} disabled={!turn} onclick={toggleDemoPace}>Demo pace</button>
			<button
				type="button"
				class="live"
				class:live-off={demoPace}
				aria-pressed={!demoPace}
				title={demoPace ? 'Stop the replay and follow the turn live' : 'Following the turn live'}
				onclick={goLive}
			>
				<span class="live-dot" aria-hidden="true"></span>Live
			</button>
			{#if float && floating}
				<button type="button" class="dock" bind:this={dockButton} onclick={() => float.dock()}>
					<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
						<rect x="1.5" y="2.5" width="11" height="9" rx="1.5"></rect>
						<path d="M8.5 2.5v9"></path>
					</svg>
					Dock beside chat
				</button>
			{:else if float}
				<!-- The tooltip repeats the button's name for sighted pointer and keyboard users. -->
				<span class="sfxw">
					<button type="button" class="sfxp" data-panel-expand aria-label="Expand to full width" onclick={expand}>
						<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
							<path d="M1.5 3v8M12.5 3v8M4 7h6M5.8 5.2L4 7l1.8 1.8M8.2 5.2L10 7 8.2 8.8"></path>
						</svg>
					</button>
					<span class="stip" aria-hidden="true">Expand to full width</span>
				</span>
			{/if}
			<button type="button" class="close" aria-label="Close security flow" onclick={close}>
				<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
					<path d="M3 3l8 8M11 3l-8 8"></path>
				</svg>
			</button>
		</div>
	</div>

	<div class="sf-body">
		{#if !turn || !flow || !focus}
			<div class="card card-empty">
				<div class="eyebrow">What's happening</div>
				<div class="card-title">Nothing to show yet.</div>
				<p class="card-body">Ask a question. The flow follows the latest answer, one stop at a time.</p>
			</div>
		{:else}
			<!-- Always in the markup: docked it lays out nothing (display: contents); floating it is
			     the row across the top. Adding or removing it would redraw everything below. -->
			<div class="toprow">
				<div class="request">
					<span class="request-dot" aria-hidden="true"></span>
					<div>
						<b>{flow.requestLabel}</b><span class="request-q">“{turn.question}”</span>
					</div>
				</div>

				<svg class="line" viewBox={geo.viewBox} role="img" aria-label={lineLabel(flow, looks)}>
					{#each geo.segments as d, i (i)}
						<path {d} class="seg-path" class:seg-reached={reached(looks[i + 1])} stroke-width="7" fill="none" stroke-linecap="round"></path>
					{/each}
					{#if mode === 'technical'}
						<g class="substeps" stroke-width="2" stroke-linecap="round">
							{#each geo.substeps as marks, i (i)}
								{#if reached(looks[i + 1])}
									{#each marks as d (d)}<path {d}></path>{/each}
								{/if}
							{/each}
						</g>
					{/if}
					{#each flow.stops as stop, i (stop.id)}
						{@const n = geo.nodes[i]}
						{@const l = looks[i]}
						{#if l === 'done'}
							<circle cx={n.x} cy={n.y} r="16" class="node-done"></circle>
							<path d="M{n.x - 7} {n.y}l5 5 9-9" class="tick" stroke-width="2.2"></path>
						{:else if l === 'final'}
							<circle cx={n.x} cy={n.y} r="38" class="halo"></circle>
							<circle cx={n.x} cy={n.y} r="24" class="node-final"></circle>
							<path d="M{n.x - 10} {n.y}l7 7 12-12" class="tick-white" stroke-width="3"></path>
						{:else if l === 'active'}
							<circle cx={n.x} cy={n.y} r="36" class="halo"></circle>
							<circle cx={n.x} cy={n.y} r="20" class="node-active"></circle>
							<circle cx={n.x} cy={n.y} r="8" class="node-core"></circle>
						{:else if l === 'failed'}
							<circle cx={n.x} cy={n.y} r="16" class="node-failed"></circle>
							<path d="M{n.x - 5} {n.y - 5}l10 10M{n.x + 5} {n.y - 5}l-10 10" class="cross" stroke-width="2.2"></path>
						{:else}
							<circle cx={n.x} cy={n.y} r="12" class="node-future" class:node-unseen={l === 'not-observed'}></circle>
						{/if}
						<text
							x={n.x}
							y={labelY(i, l)}
							text-anchor="middle"
							class="stop-label"
							class:label-active={l === 'active'}
							class:label-strong={l === 'final' || l === 'failed'}
							class:label-failed={l === 'failed'}
							class:label-quiet={l === 'future' || l === 'not-observed'}>{stop.label}</text
						>
					{/each}
				</svg>
			</div>

			<div class="focus" class:focus-wait={focus.tone === 'waiting'} class:focus-bad={focus.tone === 'failed'} class:focus-quiet={focus.status === 'not observed'}>
				<div class="focus-eyebrow">{focus.story.eyebrow}</div>
				<div class="focus-title">{focus.story.title}</div>
				<p class="focus-line">{focus.story.line}</p>
				<span class="focus-chip"><i aria-hidden="true"></i>{focus.story.chip}</span>
			</div>
			<p class="visually-hidden" aria-live="polite">{announcement}</p>

			<div class="card card-whats">
				<div class="eyebrow">What's happening</div>
				<div class="card-title">{focus.story.heading}</div>
				<p class="card-body">{focus.story.body}</p>
				{#if focus.story.note}<p class="card-note">{focus.story.note}</p>{/if}
			</div>

			<div class="card card-signals">
				<div class="eyebrow eyebrow-dark">Technical signals</div>
				{#if chips.length > 0 || mode === 'story'}
					<div class="chips">
						{#each chips as chip (chip)}<span class="chip">{chip}</span>{/each}
						{#if mode === 'story'}
							<button type="button" class="chip chip-more" onclick={() => (mode = 'technical')}>+ Details</button>
						{/if}
					</div>
				{/if}
				{#if focus.ids.length > 0}
					<div class="ids">{focus.ids.map((i) => `${i.label} ${i.value}`).join(' · ')}</div>
				{/if}
				{#if mode === 'technical'}
					<div class="divider"></div>
					<div class="signals">
						{#each signals as s (s.id)}
							<span
								class:sig-quiet={s.status === 'not observed'}
								class:sig-wait={s.status === 'pending'}
								class:sig-bad={s.tone === 'failed'}>{s.label}</span
							>
							<span
								class="sig-status"
								class:sig-quiet={s.status === 'not observed'}
								class:sig-wait={s.status === 'pending'}
								class:sig-bad={s.tone === 'failed'}>{statusText(s)}</span
							>
						{/each}
					</div>
				{/if}
			</div>

			{#if mode === 'technical'}
				<div class="card evidence">
					<button
						type="button"
						class="evidence-head"
						aria-expanded={evidenceOpen}
						aria-controls="{id}-evidence"
						onclick={() => (evidenceOpen = !evidenceOpen)}
					>
						{evidenceOpen ? '▾' : '▸'} Evidence · {flow.evidence.length} normalized events
					</button>
					{#if evidenceOpen}
						<ol class="evidence-list" id="{id}-evidence">
							{#each flow.evidence as row (row.index)}
								<li class="evidence-row">
									<span class="ev-t">{row.t}</span>
									<span class="ev-main">
										<!-- Floating, the source and the kind share a line, as the floating board sets them. -->
										<span class="ev-src">{row.src}</span>{#if floating}{' · '}{:else}<br />{/if}
										<b class="ev-kind">{row.kind}</b>
										<span class="ev-status ev-{rowTone(row)}">· {row.status}</span><br />
										<span class="ev-line">{row.line}</span>
									</span>
									<button
										type="button"
										class="ev-raw"
										aria-expanded={!!rawOpen[row.index]}
										aria-label="Raw event {row.index + 1}"
										onclick={() => (rawOpen[row.index] = !rawOpen[row.index])}>raw</button
									>
									{#if rawOpen[row.index]}
										<pre class="ev-json">{JSON.stringify(row.raw, null, 2)}</pre>
									{/if}
								</li>
							{/each}
						</ol>
					{/if}
				</div>
			{/if}
		{/if}
	</div>
</aside>

<style>
	/* Colours are the theme's security-flow palette (app.css). The three literals below have no
	   theme token: the sub-step marks, the dashed divider and the Live dot, as the mockup sets them. */
	.sf {
		--sf-mark: #a8b3bf;
		--sf-divider: #c6cdd5;
		--sf-live: #34d399;
		--sf-teal-soft: rgba(0, 157, 154, 0.1);
		--sf-halo: rgba(0, 157, 154, 0.16);

		width: 520px;
		flex-shrink: 0;
		display: flex;
		flex-direction: column;
		min-height: 0;
		overflow: hidden;
		background: var(--ovi-card);
		border-left: 1px solid var(--ovi-hairline);
		color: var(--ovi-text-primary);
		font-family: var(--ovi-font-sans);
		letter-spacing: normal;
	}

	/* ---- Header ------------------------------------------------------------------ */
	.sf-head {
		padding: 20px 26px 16px;
		border-bottom: 1px solid var(--ovi-hairline);
	}

	.eyebrow {
		font: 600 12px var(--ovi-font-condensed);
		letter-spacing: 0.12em;
		text-transform: uppercase;
		color: var(--ovi-teal-deep);
	}

	.eyebrow-dark {
		color: var(--ovi-text-strong);
	}

	.sf-title {
		margin: 4px 0;
		font-weight: 600;
		font-size: 24px;
		line-height: 1.25;
	}

	.sf-sub {
		margin: 0;
		font-size: 14.5px;
		line-height: 1.45;
		color: var(--ovi-text-secondary);
	}

	.sf-controls {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-top: 14px;
		flex-wrap: wrap;
	}

	.seg {
		display: flex;
		padding: 3px;
		border-radius: var(--ovi-radius-pill);
		background: var(--ovi-control-bg);
	}

	.seg button {
		border: 0;
		background: none;
		border-radius: var(--ovi-radius-pill);
		padding: 8px 16px;
		font: 500 14px var(--ovi-font-sans);
		color: var(--ovi-text-secondary);
		cursor: pointer;
	}

	.seg button.on {
		background: var(--ovi-card);
		color: var(--ovi-text-primary);
		box-shadow: 0 1px 2px rgba(22, 22, 22, 0.14);
	}

	.pace {
		border: 0;
		border-radius: var(--ovi-radius-pill);
		padding: 10px 16px;
		background: var(--ovi-control-bg);
		font: 500 14px var(--ovi-font-sans);
		color: var(--ovi-text-strong);
		cursor: pointer;
	}

	.pace[aria-pressed='true'] {
		background: var(--ovi-teal-deep);
		color: #ffffff;
	}

	.pace:disabled {
		cursor: not-allowed;
		opacity: 0.55;
	}

	.live {
		display: flex;
		align-items: center;
		gap: 8px;
		border: 0;
		border-radius: var(--ovi-radius-pill);
		padding: 9px 16px;
		background: var(--ovi-text-primary);
		color: #ffffff;
		font: 500 14px var(--ovi-font-sans);
		cursor: pointer;
	}

	.live-dot {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--sf-live);
	}

	.live-off .live-dot {
		background: var(--ovi-text-muted);
	}

	.close {
		width: 38px;
		height: 38px;
		margin-left: auto;
		border: 0;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ovi-control-bg);
		color: var(--ovi-text-strong);
		cursor: pointer;
	}

	.sf button:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
	}

	/* ---- Expand and dock (the approved expand-control and floating boards) ---------- */
	/* The expand button, a round 38px button like the close button, placed before it; the
	   pair sits together at the end of the row. On the light panel its tooltip is dark, the
	   approved navigation tooltip. */
	.sfxw {
		position: relative;
		display: flex;
		margin-left: auto;
	}

	.sfxw + .close,
	.dock + .close {
		margin-left: 0;
	}

	.sfxp {
		width: 38px;
		height: 38px;
		border: 0;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ovi-control-bg);
		color: var(--ovi-text-strong);
		cursor: pointer;
	}

	.sfxp:hover {
		background: var(--ovi-neutral-soft);
		color: var(--ovi-text-primary);
	}

	.stip {
		display: none;
		position: absolute;
		top: calc(100% + 10px);
		left: 50%;
		z-index: 2;
		transform: translateX(-50%);
		padding: 6px 10px;
		border-radius: 6px;
		background: var(--ovi-text-primary);
		color: #ffffff;
		font: 500 13px var(--ovi-font-sans);
		white-space: nowrap;
		box-shadow: 0 2px 8px rgba(22, 22, 22, 0.2);
	}

	.stip::before {
		content: '';
		position: absolute;
		top: -4px;
		left: 50%;
		width: 8px;
		height: 8px;
		background: var(--ovi-text-primary);
		transform: translateX(-50%) rotate(45deg);
	}

	.sfxw:hover .stip,
	.sfxp:focus-visible + .stip {
		display: block;
	}

	.dock {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		padding: 10px 16px;
		border: 0;
		border-radius: var(--ovi-radius-pill);
		background: var(--ovi-control-bg);
		color: var(--ovi-text-strong);
		font: 500 13px var(--ovi-font-sans);
		cursor: pointer;
	}

	/* ---- Body -------------------------------------------------------------------- */
	.sf-body {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		padding: 16px 26px;
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	/* The Technical view is taller than the window: every block keeps its full size and the
	   body scrolls, instead of the five-stop line being squeezed (the approved board). */
	.sf-body > * {
		flex-shrink: 0;
	}

	/* Docked, the top row lays out nothing: the request and the line are rows of the body. */
	.toprow {
		display: contents;
	}

	.request {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 11px 16px;
		border-radius: var(--ovi-radius-card);
		background: var(--ovi-surface-bg);
	}

	.request-dot {
		width: 10px;
		height: 10px;
		flex-shrink: 0;
		border-radius: 50%;
		background: var(--ovi-teal);
	}

	/* Bold as on the approved boards; the app's reset sets <b> to inherit its weight. */
	.request b {
		display: block;
		font-size: 15px;
		font-weight: 700;
	}

	.request-q {
		font-size: 14.5px;
		color: var(--ovi-text-strong);
		overflow-wrap: anywhere;
	}

	/* ---- The line ---------------------------------------------------------------- */
	.line {
		width: 100%;
		max-width: 468px;
		height: auto;
		flex-shrink: 0;
		overflow: visible;
	}

	.seg-path {
		stroke: var(--ovi-rail);
		transition: stroke 0.4s ease;
	}

	.seg-path.seg-reached {
		stroke: var(--ovi-teal);
	}

	.substeps {
		stroke: var(--sf-mark);
	}

	.node-done,
	.node-failed {
		fill: #ffffff;
		stroke-width: 2.5;
	}

	.node-done {
		stroke: var(--ovi-teal);
	}

	.node-failed {
		stroke: var(--ovi-red);
	}

	.halo {
		fill: var(--sf-halo);
	}

	.node-final {
		fill: var(--ovi-teal-deep);
	}

	.node-active {
		fill: #ffffff;
		stroke: var(--ovi-teal);
		stroke-width: 3;
	}

	.node-core {
		fill: var(--ovi-teal);
	}

	.node-future {
		fill: #ffffff;
		stroke: var(--ovi-rail);
		stroke-width: 2.5;
	}

	.node-unseen {
		stroke: var(--ovi-text-muted);
		stroke-dasharray: 4 3;
	}

	.tick,
	.tick-white,
	.cross {
		fill: none;
		stroke-linecap: round;
		stroke-linejoin: round;
	}

	.tick {
		stroke: var(--ovi-teal-deep);
	}

	.tick-white {
		stroke: #ffffff;
	}

	.cross {
		stroke: var(--ovi-red);
	}

	.stop-label {
		font-family: var(--ovi-font-sans);
		font-size: 14px;
		font-weight: 600;
		fill: var(--ovi-text-primary);
	}

	.stop-label.label-strong {
		font-weight: 700;
	}

	.stop-label.label-active {
		font-weight: 700;
		fill: var(--ovi-teal-deep);
	}

	.stop-label.label-failed {
		fill: var(--ovi-red);
	}

	.stop-label.label-quiet {
		font-weight: 400;
		fill: var(--ovi-text-helper);
	}

	/* ---- Focus card -------------------------------------------------------------- */
	.focus {
		align-self: center;
		box-sizing: border-box;
		width: 340px;
		max-width: 100%;
		padding: 12px 24px;
		border-radius: var(--ovi-radius-card-lg);
		border: 1px solid var(--ovi-hairline);
		background: var(--ovi-card);
		box-shadow: 0 6px 24px rgba(22, 22, 22, 0.08);
		text-align: center;
	}

	.focus-eyebrow {
		font: 600 12px var(--ovi-font-condensed);
		letter-spacing: 0.12em;
		text-transform: uppercase;
		color: var(--ovi-teal-deep);
	}

	.focus-title {
		margin: 3px 0;
		font-weight: 600;
		font-size: 21px;
		line-height: 1.3;
	}

	.focus-line {
		margin: 0 0 8px;
		font-size: 14px;
		color: var(--ovi-text-secondary);
	}

	.focus-chip {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 5px 12px;
		border-radius: var(--ovi-radius-pill);
		background: var(--sf-teal-soft);
		color: var(--ovi-teal-deep);
		font: 500 13.5px var(--ovi-font-sans);
	}

	.focus-chip i {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: currentColor;
		display: inline-block;
	}

	.focus-wait .focus-eyebrow {
		color: var(--ovi-amber);
	}

	.focus-wait .focus-chip {
		background: var(--ovi-amber-soft);
		color: var(--ovi-amber);
	}

	.focus-bad .focus-eyebrow {
		color: var(--ovi-red);
	}

	.focus-bad .focus-chip {
		background: var(--ovi-red-soft);
		color: var(--ovi-red);
	}

	.focus-quiet .focus-eyebrow,
	.focus-quiet .focus-chip {
		color: var(--ovi-text-helper);
	}

	.focus-quiet .focus-chip {
		background: var(--ovi-control-bg);
	}

	/* ---- Cards ------------------------------------------------------------------- */
	.card {
		padding: 14px 20px;
		border-radius: var(--ovi-radius-card);
		background: var(--ovi-surface-bg);
	}

	.card-title {
		margin: 5px 0 4px;
		font-weight: 600;
		font-size: 16.5px;
		line-height: 1.35;
	}

	.card-body {
		margin: 0;
		font-size: 14px;
		line-height: 1.5;
		color: var(--ovi-text-strong);
	}

	.card-note {
		margin: 6px 0 0;
		font-size: 12.5px;
		line-height: 1.45;
		color: var(--ovi-text-helper);
	}

	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-top: 9px;
	}

	.chip {
		border: 0;
		border-radius: var(--ovi-radius-pill);
		padding: 5px 12px;
		background: var(--sf-teal-soft);
		color: var(--ovi-teal-deep);
		font: 600 13px var(--ovi-font-condensed);
	}

	.chip-more {
		background: var(--ovi-neutral-soft);
		color: var(--ovi-text-strong);
		cursor: pointer;
	}

	.ids {
		margin-top: 8px;
		font: 13px var(--ovi-font-mono);
		color: var(--ovi-text-strong);
		overflow-wrap: anywhere;
	}

	.divider {
		margin: 12px 0 8px;
		border-top: 1px dashed var(--sf-divider);
	}

	.signals {
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		gap: 7px 14px;
		font: 13px/1.45 var(--ovi-font-mono);
		color: var(--ovi-text-primary);
	}

	/* Left-aligned in its own column, as the approved Technical board sets it. */
	.sig-status {
		color: var(--ovi-teal-deep);
	}

	.sig-quiet,
	.sig-status.sig-quiet {
		color: var(--ovi-text-helper);
	}

	.sig-wait,
	.sig-status.sig-wait {
		color: var(--ovi-amber);
	}

	.sig-bad,
	.sig-status.sig-bad {
		color: var(--ovi-red);
	}

	/* ---- Evidence ---------------------------------------------------------------- */
	.evidence {
		background: var(--ovi-card);
		border: 1px solid var(--ovi-hairline-strong);
	}

	.evidence-head {
		padding: 0;
		border: 0;
		background: none;
		font: 600 12px var(--ovi-font-mono);
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--ovi-text-strong);
		cursor: pointer;
		text-align: left;
	}

	.evidence-list {
		margin: 8px 0 0;
		padding: 0;
		list-style: none;
		display: flex;
		flex-direction: column;
		font: 12px/1.45 var(--ovi-font-mono);
	}

	.evidence-row {
		display: grid;
		grid-template-columns: 58px minmax(0, 1fr) auto;
		gap: 10px;
		align-items: start;
		padding: 7px 0;
		border-top: 1px solid var(--ovi-hairline);
	}

	.ev-t {
		color: var(--ovi-text-helper);
	}

	.ev-main {
		min-width: 0;
		overflow-wrap: anywhere;
	}

	.ev-src {
		color: var(--ovi-text-strong);
	}

	.ev-kind {
		font-weight: 500;
		color: var(--ovi-text-primary);
	}

	.ev-ok {
		color: var(--ovi-teal-deep);
	}

	.ev-wait {
		color: var(--ovi-amber);
	}

	.ev-bad {
		color: var(--ovi-red);
	}

	.ev-line {
		font-family: var(--ovi-font-sans);
		font-size: 13px;
		color: var(--ovi-text-secondary);
	}

	.ev-raw {
		border: 0;
		border-radius: 6px;
		padding: 2px 8px;
		background: var(--ovi-control-bg);
		font: 12px var(--ovi-font-mono);
		color: var(--ovi-text-strong);
		cursor: pointer;
	}

	.ev-json {
		grid-column: 1 / -1;
		margin: 4px 0 0;
		padding: 10px 12px;
		max-height: 320px;
		overflow: auto;
		border-radius: 8px;
		background: var(--ovi-surface-bg);
		font: 11.5px/1.5 var(--ovi-font-mono);
		color: var(--ovi-text-primary);
		white-space: pre-wrap;
		word-break: break-all;
	}

	/* ---- Floating, full width (the approved floating board) -------------------------- */
	/* Fixed 24px inside the window, over ChatWorkspace's scrim (z-index 20). */
	.sf.floating {
		position: fixed;
		inset: 24px;
		z-index: 21;
		width: auto;
		border: 1px solid var(--ovi-hairline-strong);
		border-radius: 12px;
		overflow: hidden;
		box-shadow: 0 24px 64px rgba(0, 0, 0, 0.35);
	}

	/* The title on the left, the controls on the right. */
	.floating .sf-head {
		display: flex;
		align-items: flex-end;
		gap: 32px;
		padding: 20px 26px 16px;
	}

	.floating .sf-controls {
		margin: 0 0 0 auto;
		flex-shrink: 0;
	}

	/* The request and the line across the top; the result card and "What's happening" side by
	   side under it, the Technical signals under both, and the Evidence in a third column that
	   scrolls on its own. */
	.floating .sf-body {
		display: grid;
		grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1.5fr);
		grid-template-rows: auto auto minmax(0, 1fr);
		gap: 14px 18px;
		padding: 14px 26px 18px;
	}

	.floating .toprow {
		grid-column: 1 / -1;
		display: grid;
		grid-template-columns: 300px minmax(0, 1fr);
		gap: 24px;
		align-items: center;
	}

	.floating .line {
		display: block;
		max-width: none;
	}

	.floating .sf-body > .focus {
		grid-column: 1;
		grid-row: 2;
		align-self: stretch;
		width: auto;
		display: flex;
		flex-direction: column;
		justify-content: center;
		align-items: center;
	}

	.floating .sf-body > .card-whats {
		grid-column: 2;
		grid-row: 2;
	}

	.floating .sf-body > .card-signals {
		grid-column: 1 / 3;
		grid-row: 3;
		align-self: start;
	}

	.floating .sf-body > .evidence {
		grid-column: 3;
		grid-row: 2 / 4;
		display: flex;
		flex-direction: column;
		min-height: 0;
		overflow: auto;
	}

	.floating .evidence-row {
		padding: 5px 0;
	}

	.floating .sf-body > .card-empty {
		grid-column: 1 / -1;
	}

	@media (prefers-reduced-motion: reduce) {
		.seg-path {
			transition: none;
		}
	}

	/* Screens 960px and narrower: the panel sits under the chat, full width (ChatWorkspace). */
	@media (max-width: 960px) {
		/* ChatWorkspace stacks the chat and the panel in one window-high column here. The panel
		   takes an equal share of that height and scrolls as one piece, header included, so the
		   chat above it keeps its own share instead of being pushed under the panel. */
		.sf {
			flex: 1 1 0;
			width: 100%;
			overflow-y: auto;
			border-left: 0;
			border-top: 1px solid var(--ovi-hairline);
		}

		.sf-head {
			padding: 16px 16px 12px;
		}

		.sf-title {
			font-size: 21px;
		}

		.sf-body {
			flex: none;
			overflow: visible;
			padding: 12px 16px;
		}

		.card {
			padding: 12px 16px;
		}

		/* A long status ("not observed in this flow") wraps instead of squeezing every label. */
		.signals {
			grid-template-columns: minmax(0, 1fr) fit-content(9em);
		}

		/* The panel already takes the full width here: no full-width control. */
		.sfxw {
			display: none;
		}

		/* The close button goes back to the end of the row. */
		.sfxw + .close {
			margin-left: auto;
		}
	}
</style>
