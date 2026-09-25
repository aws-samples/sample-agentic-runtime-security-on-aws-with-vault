<!--
  ChatWorkspace — the chat column plus the right-hand panel slot, shared by every chat page.

  Layout: [ chat column | panel ]. The left navigation comes from +layout.svelte; on screens
  960px and narrower it is a drawer behind a top bar, and the chat fills the rest of the window.

  Header buttons
    - "View security flow": disabled until `onSecurityFlowToggle` is passed. `securityFlowOpen`
      drives aria-pressed and the pressed style. `securityFlowControls` is the id of the panel
      it opens (aria-controls).
    - "Agent log": disabled until `onAgentLogToggle` is passed. `agentLogOpen` drives
      aria-pressed; `agentLogCount` shows the entry badge when > 0. `agentLogControls` is the
      id of the panel it opens (aria-controls).

  Right-hand panel
    `panel` is a snippet rendered beside the chat column. The page owns the chat state, so the
    page decides which panel is open and renders it here, for example:

      {#snippet panel()}
        {#if openPanel === 'log'}<AgentLogPanel id="agent-log" turns={log.turns} systems="..." onclose={...} />{/if}
      {/snippet}

    The panel component sets its own landmark (<aside aria-label="...">) and takes its width
    from --ovi-panel-width, which this workspace sets: 420px, or 520px while the left
    navigation is collapsed to its rail on a wide screen (the rail frees 208px; the panel
    takes 100 of them and the chat the rest). A new panel reads it the same way:
    width: var(--ovi-panel-width, 420px).

  Floating a panel full width (wider than 960px only)
    A presenter can float the open panel over the whole window and dock it back. The state is
    kept here, so pages pass nothing: a panel reads it with getPanelFloat() (below) and draws
    an expand button, or a "Dock beside chat" button while it floats.
      - expand(id) floats the panel whose element has that id: it is fixed 24px inside the
        window over the scrim (--ovi-scrim), and every element outside it is made inert.
        Tab and Shift+Tab wrap inside the panel.
      - dock() puts it back beside the chat and focuses the panel's expand button, which
        carries the attribute data-panel-expand. Escape (the panel handles it; this workspace
        catches it too when focus is outside the panel) and a click on the scrim dock it.
      - release(id) drops the float without moving focus. A panel calls it before it closes
        and when it unmounts, so the page behind is never left inert.
    Floating is not kept across a reload, and ends by itself when the window narrows to
    960px or less, where the panel already covers the chat.
-->
<script module lang="ts">
	import { getContext } from 'svelte';

	export interface Suggestion {
		label: string;
		/** 'warn' renders the red chip used for the refund prompt. */
		tone?: 'default' | 'warn';
		onselect: () => void;
	}

	/** The float contract a panel in the `panel` slot uses. See the header comment. */
	export interface PanelFloat {
		/** The id of the panel floating full width, or null while it is docked. */
		readonly floating: string | null;
		expand(id: string): void;
		dock(): void;
		release(id: string): void;
	}

	const PANEL_FLOAT = Symbol('ovi-panel-float');

	/** The workspace's float state, for a panel rendered in its `panel` slot. Undefined elsewhere. */
	export function getPanelFloat(): PanelFloat | undefined {
		return getContext<PanelFloat | undefined>(PANEL_FLOAT);
	}
</script>

<script lang="ts">
	import { setContext, tick, type Snippet } from 'svelte';
	import { TextArea } from 'carbon-components-svelte';

	interface Props {
		/** Page heading (rendered as the h1), e.g. "Banking Agent". */
		title: string;
		/** Italic line under the title. */
		subtitle: string;
		/** Glyph inside the round header badge. Decorative. */
		icon: Snippet;
		/** Non-interactive status pill, e.g. "Identity-bound". */
		statusLabel: string;

		agentLogOpen?: boolean;
		agentLogCount?: number;
		agentLogControls?: string;
		onAgentLogToggle?: () => void;

		securityFlowOpen?: boolean;
		securityFlowControls?: string;
		onSecurityFlowToggle?: () => void;

		/** The conversation. Rendered inside the scrolling message region. */
		children: Snippet;
		/** The scrolling message region, bound so pages can auto-scroll it. */
		messagesEl?: HTMLDivElement;

		suggestions?: Suggestion[];

		/** Composer text, two-way bound. */
		value: string;
		/** True while a reply is in flight: disables the suggestions, the input and Send. */
		busy: boolean;
		inputId: string;
		inputLabel: string;
		placeholder: string;
		onsend: () => void;
		/** Centred line under the composer. */
		hint: string;

		/** Right-hand panel (Agent Log, Security Flow). */
		panel?: Snippet;
	}

	let {
		title,
		subtitle,
		icon,
		statusLabel,
		agentLogOpen = false,
		agentLogCount = 0,
		agentLogControls,
		onAgentLogToggle,
		securityFlowOpen = false,
		securityFlowControls,
		onSecurityFlowToggle,
		children,
		messagesEl = $bindable(),
		suggestions = [],
		value = $bindable(''),
		busy,
		inputId,
		inputLabel,
		placeholder,
		onsend,
		hint,
		panel
	}: Props = $props();

	function handleKeydown(e: KeyboardEvent) {
		// Enter sends, Shift+Enter inserts a newline. Ignore Enter while an IME is composing.
		if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
			e.preventDefault();
			onsend();
		}
	}

	// ---- Floating a panel full width ---------------------------------------------------
	// Must match the max-width media query below: the panel already covers the chat there.
	const NARROW = '(max-width: 960px)';

	let floating = $state<string | null>(null);

	/** The elements this workspace made inert, so docking restores exactly those. */
	let madeInert: Element[] = [];
	/** Elements that draw nothing: left as they are. */
	const INERT_SKIP = new Set(['SCRIPT', 'STYLE', 'LINK', 'META', 'TEMPLATE', 'NOSCRIPT']);

	// Everything outside the panel, up to <body>, except the scrim (a click on it docks) and
	// anything already inert (the page left that as it was, so it stays as it was).
	function makeOthersInert(panel: HTMLElement) {
		restoreInert();
		for (let node: HTMLElement | null = panel; node && node !== document.body; node = node.parentElement) {
			for (const sibling of node.parentElement?.children ?? []) {
				if (sibling === node || INERT_SKIP.has(sibling.tagName) || sibling.hasAttribute('data-panel-scrim')) continue;
				if (sibling.hasAttribute('inert')) continue;
				sibling.setAttribute('inert', '');
				madeInert.push(sibling);
			}
		}
	}

	function restoreInert() {
		for (const el of madeInert) el.removeAttribute('inert');
		madeInert = [];
	}

	function expand(id: string) {
		if (window.matchMedia(NARROW).matches) return;
		floating = id;
	}

	async function dock() {
		const id = floating;
		if (!id) return;
		floating = null;
		restoreInert();
		await tick();
		document.getElementById(id)?.querySelector<HTMLElement>('[data-panel-expand]')?.focus();
	}

	function release(id: string) {
		if (floating !== id) return;
		floating = null;
		restoreInert();
	}

	setContext<PanelFloat>(PANEL_FLOAT, {
		get floating() {
			return floating;
		},
		expand,
		dock,
		release
	});

	// After the DOM shows the panel floating (and the scrim), the rest of the page goes inert.
	$effect(() => {
		const id = floating;
		const panel = id ? document.getElementById(id) : null;
		if (!panel) return;
		makeOthersInert(panel);
		return restoreInert;
	});

	// Narrowing the window to 960px or less ends the float: the panel covers the chat there.
	$effect(() => {
		const query = window.matchMedia(NARROW);
		const onChange = () => {
			if (query.matches && floating) release(floating);
		};
		query.addEventListener('change', onChange);
		return () => query.removeEventListener('change', onChange);
	});

	/** What Tab reaches inside the floating panel, in document order. */
	function focusables(panel: HTMLElement): HTMLElement[] {
		return [
			...panel.querySelectorAll<HTMLElement>(
				'a[href], button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
			)
		].filter((el) => el.getClientRects().length > 0);
	}

	// While a panel floats: Tab and Shift+Tab wrap inside it, and Escape docks it when focus
	// is not in the panel (the panel handles its own Escape and stops it there).
	function onWindowKeydown(e: KeyboardEvent) {
		const panel = floating ? document.getElementById(floating) : null;
		if (!panel) return;
		if (e.key === 'Escape') {
			e.preventDefault();
			dock();
			return;
		}
		if (e.key !== 'Tab') return;
		const items = focusables(panel);
		if (items.length === 0) {
			e.preventDefault();
			return;
		}
		const first = items[0];
		const last = items[items.length - 1];
		const active = document.activeElement;
		const inside = active instanceof HTMLElement && panel.contains(active);
		if (e.shiftKey && (active === first || !inside)) {
			e.preventDefault();
			last.focus();
		} else if (!e.shiftKey && (active === last || !inside)) {
			e.preventDefault();
			first.focus();
		}
	}
</script>

<svelte:window onkeydown={onWindowKeydown} />

<div class="workspace">
	<section class="chat" aria-labelledby="chat-title">
		<header class="chat-header">
			<span class="chat-header-icon" aria-hidden="true">{@render icon()}</span>
			<div class="chat-header-text">
				<h1 id="chat-title" class="chat-title">{title}</h1>
				<p class="chat-subtitle">{subtitle}</p>
			</div>
			<div class="chat-header-pills">
				<span class="pill pill-status"><span class="pill-dot" aria-hidden="true"></span>{statusLabel}</span>
				<button
					type="button"
					class="pill pill-flow"
					class:pill-flow-on={securityFlowOpen}
					aria-pressed={securityFlowOpen}
					aria-controls={securityFlowControls}
					disabled={!onSecurityFlowToggle}
					onclick={() => onSecurityFlowToggle?.()}
				>
					<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
						<path d="M1 10c3-6 5 2 8-4 1-2 3-2 4-1"></path>
					</svg>
					View security flow
				</button>
				<button
					type="button"
					class="pill pill-log"
					aria-pressed={agentLogOpen}
					aria-controls={agentLogControls}
					disabled={!onAgentLogToggle}
					onclick={() => onAgentLogToggle?.()}
				>
					<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
						<path d="M2 3l4 4-4 4M7 11h5"></path>
					</svg>
					Agent log
					{#if agentLogCount > 0}
						<span class="pill-badge">{agentLogCount}<span class="visually-hidden"> entries</span></span>
					{/if}
				</button>
			</div>
		</header>

		<!-- tabindex makes the scrolling region reachable for keyboard scrolling. -->
		<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
		<div
			class="chat-messages"
			bind:this={messagesEl}
			role="log"
			aria-live="polite"
			aria-label="Conversation"
			tabindex="0"
		>
			{@render children()}
		</div>

		{#if suggestions.length > 0}
			<div class="chat-suggestions" role="group" aria-label="Suggested questions">
				{#each suggestions as suggestion (suggestion.label)}
					<button
						type="button"
						class="suggestion"
						class:suggestion-warn={suggestion.tone === 'warn'}
						disabled={busy}
						onclick={suggestion.onselect}
					>
						{suggestion.label}
					</button>
				{/each}
			</div>
		{/if}

		<div class="chat-composer">
			<TextArea
				id={inputId}
				bind:value
				on:keydown={handleKeydown}
				labelText={inputLabel}
				hideLabel
				{placeholder}
				rows={1}
				disabled={busy}
			/>
			<button
				type="button"
				class="send"
				aria-label="Send"
				disabled={busy || !value.trim()}
				onclick={onsend}
			>
				<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
					<path d="M9 15V3M4 8l5-5 5 5"></path>
				</svg>
			</button>
		</div>
		<p class="chat-hint">{hint}</p>
	</section>

	{#if floating}
		<!-- Pointer users dock the floating panel on the scrim; keyboard users have Escape. -->
		<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
		<div class="panel-scrim" data-panel-scrim aria-hidden="true" onclick={() => dock()}></div>
	{/if}

	{@render panel?.()}
</div>

<style>
	/* Carbon's body type sets 0.16px tracking; the design sets chat text in the font's normal
	   letter spacing. Text that sets its own tracking (the uppercase pills) keeps it. */
	.workspace {
		--ovi-panel-width: 420px;
		display: flex;
		height: 100vh;
		height: 100dvh;
		min-height: 0;
		letter-spacing: normal;
	}

	/* The left navigation is the 72px rail ($lib/nav-rail, +layout.svelte): the panel widens.
	   Wide screens only, the exact complement of the narrow query below. */
	@media not all and (max-width: 960px) {
		:global(html[data-ovi-nav='collapsed']) .workspace {
			--ovi-panel-width: 520px;
		}
	}

	.chat {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		background: var(--ovi-card);
	}

	/* ---- Header ------------------------------------------------------------------- */
	.chat-header {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 18px 24px;
		border-bottom: 1px solid var(--ovi-hairline);
		flex-wrap: wrap;
	}

	.chat-header-icon {
		width: 44px;
		height: 44px;
		flex-shrink: 0;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ovi-nav-bg);
		color: var(--ovi-brand-primary);
	}

	.chat-header-text {
		min-width: 0;
	}

	.chat-title {
		margin: 0;
		font-weight: 600;
		font-size: 18px;
		line-height: 1.3;
		color: var(--ovi-text-primary);
	}

	.chat-subtitle {
		margin: 0;
		font-size: 12.5px;
		font-style: italic;
		color: var(--ovi-text-helper);
	}

	.chat-header-pills {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
	}

	.pill {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 9px 14px;
		border-radius: var(--ovi-radius-pill);
		border: 1px solid var(--ovi-border);
		background: var(--ovi-control-bg);
		color: var(--ovi-text-strong);
		font: 600 12px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		white-space: nowrap;
	}

	button.pill {
		cursor: pointer;
	}

	button.pill:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
	}

	button.pill:disabled {
		cursor: not-allowed;
		opacity: 0.55;
	}

	.pill-status {
		background: var(--ovi-ok-bg);
		border-color: var(--ovi-ok-border);
		color: var(--ovi-ok-text);
	}

	.pill-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--ovi-ok-dot);
	}

	.pill-flow:not(:disabled):hover {
		border-color: var(--ovi-text-helper);
	}

	.pill-flow-on {
		background: var(--ovi-teal-deep);
		border-color: var(--ovi-teal-deep);
		color: #ffffff;
	}

	.pill-log {
		background: var(--ovi-ink);
		border-color: var(--ovi-ink);
		color: #ffffff;
	}

	.pill-badge {
		padding: 1px 7px;
		border-radius: var(--ovi-radius-pill);
		background: var(--ovi-brand-primary);
		color: #ffffff;
		font: 600 11px var(--ovi-font-sans);
		letter-spacing: 0;
	}

	/* ---- Conversation ------------------------------------------------------------- */
	/* position: relative makes the log the containing block of the screen-reader-only
	   labels (.visually-hidden is absolutely positioned). Without it they are laid out
	   against the page, not the log, so a long conversation stretches the whole page. */
	.chat-messages {
		position: relative;
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 22px 24px;
		background: var(--ovi-surface-bg);
	}

	.chat-messages:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: -2px;
	}

	/* Carbon components in the conversation (the error notification, the consent card's
	   buttons) set 0.16px on their own text, so they do not inherit the rule above. */
	.chat-messages :global(.bx--inline-notification__title),
	.chat-messages :global(.bx--inline-notification__subtitle),
	.chat-messages :global(.bx--btn) {
		letter-spacing: normal;
	}

	/* ---- Suggestions -------------------------------------------------------------- */
	.chat-suggestions {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		padding: 12px 24px 0;
		background: var(--ovi-card);
	}

	.suggestion {
		padding: 6px 14px;
		border-radius: var(--ovi-radius-pill);
		border: 1px solid var(--ovi-border);
		background: var(--ovi-card);
		color: var(--ovi-text-secondary);
		font: 13.5px var(--ovi-font-sans);
		text-align: left;
		cursor: pointer;
	}

	.suggestion:not(:disabled):hover {
		border-color: var(--ovi-brand-primary);
		color: var(--ovi-brand-deep);
	}

	.suggestion-warn {
		color: var(--ovi-red);
		border-color: var(--ovi-red-soft);
	}

	.suggestion-warn:not(:disabled):hover {
		border-color: var(--ovi-red);
		color: var(--ovi-red);
	}

	.suggestion:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
	}

	.suggestion:disabled {
		cursor: not-allowed;
		opacity: 0.55;
	}

	/* ---- Composer ----------------------------------------------------------------- */
	.chat-composer {
		display: flex;
		align-items: flex-end;
		gap: 12px;
		padding: 12px 24px 8px;
		background: var(--ovi-card);
	}

	.chat-composer :global(.bx--form-item) {
		flex: 1;
		min-width: 0;
	}

	.chat-composer :global(.bx--text-area) {
		box-sizing: border-box;
		min-height: 58px;
		max-height: 160px;
		field-sizing: content;
		padding: 17px 18px;
		border: 1px solid var(--ovi-border);
		border-radius: var(--ovi-radius-bubble);
		background: var(--ovi-surface-bg);
		color: var(--ovi-text-primary);
		font: 15.5px/22px var(--ovi-font-sans);
		letter-spacing: normal;
		resize: none;
	}

	/* Carbon gives the placeholder its own 14px type; the design shows it at the typed-text size. */
	.chat-composer :global(.bx--text-area::placeholder) {
		color: var(--ovi-text-helper);
		opacity: 1;
		font-size: inherit;
		letter-spacing: inherit;
	}

	.chat-composer :global(.bx--text-area:disabled) {
		cursor: not-allowed;
	}

	.send {
		width: 52px;
		height: 52px;
		flex-shrink: 0;
		margin-bottom: 3px;
		border: 0;
		border-radius: var(--ovi-radius-bubble);
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ovi-brand-primary);
		color: #ffffff;
		cursor: pointer;
	}

	.send:not(:disabled):hover {
		background: var(--ovi-brand-deep);
	}

	.send:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
	}

	.send:disabled {
		background: var(--ovi-send-disabled);
		cursor: not-allowed;
	}

	.chat-hint {
		margin: 0;
		padding: 0 24px 12px;
		background: var(--ovi-card);
		text-align: center;
		font-size: 12.5px;
		color: var(--ovi-text-helper);
	}

	/* ---- Floating panel ------------------------------------------------------------ */
	/* Under the floating panel (z-index 21, set by the panel) and over the navigation. */
	.panel-scrim {
		position: fixed;
		inset: 0;
		z-index: 20;
		background: var(--ovi-scrim);
	}

	/* Screens 960px and narrower: the navigation is a drawer behind a top bar
	   (+layout.svelte), so the chat fills the window under the bar. The message log keeps its
	   own scroll, new replies are scrolled into view, and the composer stays on screen. */
	@media (max-width: 960px) {
		.workspace {
			flex-direction: column;
			height: calc(100vh - var(--ovi-bar-height));
			height: calc(100dvh - var(--ovi-bar-height));
		}

		.chat {
			min-height: 0;
		}

		/* The pills move to a row of their own under the title. */
		.chat-header {
			padding: 12px 16px;
			gap: 10px;
		}

		.chat-header-pills {
			margin-left: 0;
			width: 100%;
		}

		.chat-messages {
			padding: 16px;
		}

		/* One row of chips that scrolls sideways. The 4px bottom padding keeps the focus ring
		   of a focused chip inside the scroller, which clips on both axes. */
		.chat-suggestions {
			flex-wrap: nowrap;
			overflow-x: auto;
			padding: 10px 16px 4px;
		}

		.suggestion {
			flex-shrink: 0;
			white-space: nowrap;
		}

		.chat-composer {
			padding: 6px 16px;
		}

		.chat-hint {
			padding: 0 12px 10px;
			font-size: 12px;
		}
	}
</style>
