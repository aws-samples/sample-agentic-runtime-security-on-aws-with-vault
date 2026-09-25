<!--
  AuditTraceCard — Issue #68 · Audit Trace card: each answer links to the audit records
  every system wrote for it.

  Collapsed, it is one line under an answer: "Audit trace · click to expand", who the turn
  acted as, and how long it took. Expanded:

  - Use Case 3, a refund that went through (the turn has an agent:audit_seed and a request
    ID): the delegated token and the Vault lease the refund used, the three checks, and
    the audit stream — the audit_correlation rows Athena holds for that request ID, fetched
    from GET /api/audit-trace. The records land about 60 s after the refund, so while the
    card is open it asks again every 10 s until all three planes (agent, Vault, Postgres)
    are in, for at most 4 minutes; Retry starts again. If the route answers that the
    sign-in has ended ($lib/session-ended), the browser goes to sign-in instead.
  - Every other turn (Use Case 1, Use Case 2, a Use Case 3 turn with no refund): the live
    facts the turn's own events reported — credential kinds, Vault paths, leases,
    time-to-live. Nothing is queried.

  Props: `turn` is the answer's Turn from the page's TurnLog ($lib/turn-events.svelte).
  A chat page passes `useCase` and `turn` only:

        <AuditTraceCard useCase={3} {turn} />

  and the card finds the audit key itself: the request ID of the turn's agent:audit_seed,
  before the turn's first request ID. `requestId` overrides that, so a page never passes
  `turn.requestId` — in a turn that used two tools it is the wrong one.

  The card shows no credential value: only metadata and a few non-secret claims.
-->
<script lang="ts">
	import { SvelteSet } from 'svelte/reactivity';
	import {
		REQUEST_ID_PATTERN,
		auditStreamRows,
		formatAmount,
		formatClock,
		formatDuration,
		liveFactRows,
		turnAuditFacts,
		type AuditListRow,
		type AuditSource,
		type AuditTraceErrorResponse,
		type AuditTraceResponse,
		type AuditUseCase
	} from '$lib/audit-trace';
	import { goToSignIn, isSessionEnded } from '$lib/session-ended';
	import type { Turn } from '$lib/turn-events.svelte';

	interface Props {
		useCase: AuditUseCase;
		turn: Turn | undefined;
		/** Overrides the audit key the card finds in `turn`. Chat pages leave it unset. */
		requestId?: string;
		/**
		 * The page's turns. A refund's amount and account are in the approval request of the
		 * turn before the one that completes it; the card finds them there.
		 */
		turns?: Turn[];
	}

	let { useCase, requestId, turn, turns }: Props = $props();

	/** How often an open card asks Athena again while records are still landing. */
	const POLL_MS = 10_000;
	/** How long it keeps asking before it stops and offers Retry. */
	const POLL_CAP_MS = 240_000;

	const bodyId = $props.id();

	let expanded = $state(false);
	let response = $state<AuditTraceResponse | null>(null);
	let error = $state<string | null>(null);
	let loading = $state(false);
	let stopped = $state(false);
	let copied = $state(false);
	let attempt = $state(0);
	const openRows = new SvelteSet<string>();

	const facts = $derived(turnAuditFacts(turn, requestId, turns));
	/** The request ID to query Athena for, or undefined when this turn has no audit_correlation row to find. */
	const traceId = $derived(
		useCase === 3 && facts.seed !== undefined && facts.requestId && REQUEST_ID_PATTERN.test(facts.requestId)
			? facts.requestId
			: undefined
	);
	const streamRows = $derived(response ? auditStreamRows(response.rows) : []);
	const factRows = $derived(liveFactRows(turn?.events ?? []));
	const duration = $derived(formatDuration(facts.durationMs));

	const meta = $derived.by(() => {
		const parts: string[] = [];
		if (useCase === 1) {
			if (facts.serviceAccount) parts.push(`service account ${facts.serviceAccount}`);
			if (facts.vaultRole) parts.push(`vault role ${facts.vaultRole}`);
		} else {
			if (facts.requestId) parts.push(`request ${facts.requestId}`);
			if (useCase === 3 && facts.authorizationType) parts.push(facts.authorizationType);
			if (facts.sub) parts.push(`sub ${facts.sub}`);
			if (useCase === 2 && facts.dbRole) parts.push(facts.dbRole);
		}
		return parts.length > 0 ? parts.join(' · ') : 'no identity facts reported for this turn';
	});

	const details = $derived(
		[facts.authorizationType, formatAmount(facts.amount, facts.currency), facts.accountId].filter(Boolean).join(' · ') ||
			'—'
	);

	const SOURCE_CLASS: Record<AuditSource, string> = {
		agent: 'src-agent',
		vault: 'src-vault',
		postgres: 'src-postgres',
		kubernetes: 'src-kubernetes',
		ivia: 'src-ivia',
		'aws sts': 'src-sts'
	};

	$effect(() => {
		const id = traceId;
		if (!expanded || !id) return;
		void attempt; // Retry re-runs this effect

		let cancelled = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		let controller: AbortController | undefined;
		const started = Date.now();
		stopped = false;
		error = null;

		async function poll(): Promise<void> {
			controller = new AbortController();
			loading = true;
			let body: AuditTraceResponse;
			try {
				const res = await fetch(`/api/audit-trace?requestId=${encodeURIComponent(id!)}`, {
					headers: { Accept: 'application/json' },
					signal: controller.signal
				});
				const parsed = (await res.json().catch(() => null)) as AuditTraceResponse | AuditTraceErrorResponse | null;
				if (cancelled) return;
				if (isSessionEnded(res.status, parsed)) {
					goToSignIn();
					return;
				}
				if (!res.ok || parsed === null || 'error' in parsed) {
					error =
						parsed !== null && 'error' in parsed ? parsed.error : `The audit query failed (HTTP ${res.status})`;
					return;
				}
				body = parsed;
			} catch {
				if (!cancelled) error = 'Could not reach the banking UI server';
				return;
			} finally {
				if (!cancelled) loading = false;
			}
			response = body;
			error = null;
			if (body.status === 'complete') return;
			if (Date.now() - started + POLL_MS > POLL_CAP_MS) {
				stopped = true;
				return;
			}
			timer = setTimeout(poll, POLL_MS);
		}

		void poll();
		return () => {
			cancelled = true;
			clearTimeout(timer);
			controller?.abort();
			loading = false;
		};
	});

	function toggleRow(key: string) {
		if (openRows.has(key)) openRows.delete(key);
		else openRows.add(key);
	}

	async function copyRequestId() {
		if (!facts.requestId) return;
		try {
			await navigator.clipboard.writeText(facts.requestId);
			copied = true;
			setTimeout(() => (copied = false), 1500);
		} catch {
			// Clipboard refused (insecure context or permission): the ID is still on screen.
		}
	}
</script>

{#snippet recordRow(row: AuditListRow)}
	<li>
		<button
			type="button"
			class="row"
			aria-expanded={openRows.has(row.key)}
			onclick={() => toggleRow(row.key)}
		>
			<span class="caret" aria-hidden="true">{openRows.has(row.key) ? '▾' : '▸'}</span>
			<span class="when">{formatClock(row.at)}</span>
			<span class="src {SOURCE_CLASS[row.source]}">{row.source}</span>
			<span class="what">{row.summary}</span>
		</button>
		{#if openRows.has(row.key)}
			<dl class="record">
				{#each row.fields as [name, value], i (i)}
					<dt>{name}</dt>
					<dd>{value}</dd>
				{/each}
			</dl>
		{/if}
	</li>
{/snippet}

{#snippet waitRow(text: string)}
	<li class="row row-wait" aria-live="polite">
		<span aria-hidden="true">◌</span><span>—</span><span>…</span><span>{text}</span>
	</li>
{/snippet}

<section class="audit-card" aria-label="Audit trace">
	<button
		type="button"
		class="trace-head"
		class:open={expanded}
		aria-expanded={expanded}
		aria-controls={bodyId}
		onclick={() => (expanded = !expanded)}
	>
		<span class="shield" aria-hidden="true">
			<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5">
				<path d="M7 1l5 2v4c0 3-2.2 5-5 6-2.8-1-5-3-5-6V3z"></path>
				<path d="M4.8 7l1.6 1.6L9.4 5.6"></path>
			</svg>
		</span>
		<span class="trace-text">
			<span class="tlabel">{expanded ? 'Audit trace' : 'Audit trace · click to expand'}</span>
			<span class="tmeta">{meta}</span>
		</span>
		{#if duration}
			<span class="ms">{duration}</span>
		{/if}
	</button>

	{#if expanded}
		<div class="trace-body" id={bodyId}>
			{#if traceId}
				<div class="panels">
					<div class="panel">
						<div class="panel-head">
							<span class="panel-title title-ivia">IBM Verify Identity Access · delegated token</span>
							<button type="button" class="copy" onclick={copyRequestId} aria-label="Copy the request ID">
								{copied ? 'Copied' : 'Copy ID'}
							</button>
						</div>
						<div class="kv"><span class="k">grant</span><span>token exchange (RFC 8693)</span></div>
						<div class="kv"><span class="k">subject</span><span>{facts.sub ?? '—'}</span></div>
						<div class="kv"><span class="k">details</span><span>{details}</span></div>
						<div class="kv">
							<span class="k">ttl</span><span>{facts.delegatedTtlSeconds !== undefined ? `${facts.delegatedTtlSeconds}s` : '—'}</span>
						</div>
					</div>
					<div class="panel">
						<div class="panel-title title-vault">Vault lease</div>
						<div class="kv"><span class="k">role</span><span>{facts.dbRole ?? '—'}</span></div>
						<div class="kv"><span class="k">lease</span><span>{facts.lease?.leaseId ?? '—'}</span></div>
						<div class="kv">
							<span class="k">ttl</span><span>{facts.lease?.ttlSeconds !== undefined ? `${facts.lease.ttlSeconds}s` : '—'} · short-lived</span>
						</div>
						<div class="kv"><span class="k">issued</span><span>after approval only</span></div>
					</div>
				</div>

				<div class="checks">
					<div class="check">
						<div class="check-title">✓ Authorized</div>
						<p>You approved this exact refund on your phone. No approval: no delegated token, no write credential, no INSERT.</p>
					</div>
					<div class="check">
						<div class="check-title">✓ Least-privilege</div>
						<p>The write credential exists only for this refund. Listing transactions used the separate read-only role, uc3-readonly.</p>
					</div>
					<div class="check">
						<div class="check-title">✓ Auditable</div>
						<p>One request ID joins the agent's anchor, Vault's audit log and Postgres pgaudit in Athena's audit_correlation view.</p>
					</div>
				</div>

				<div class="stream">
					<div class="stream-label">Audit stream · Athena audit_correlation · click any row for the full record</div>
					<div class="note">Records reach Athena about 60 s after the request (Firehose buffer). Rows below appear as they land.</div>
					<ul class="rows">
						{#each streamRows as row (row.key)}
							{@render recordRow(row)}
						{/each}
						{#if error}
							<li class="row row-error" role="alert">
								<span aria-hidden="true">!</span><span>—</span><span>error</span>
								<span class="error-text">
									{error}
									<button type="button" class="retry" onclick={() => attempt++}>Retry</button>
								</span>
							</li>
						{:else if loading && response === null}
							{@render waitRow('querying Athena…')}
						{:else if stopped}
							<li class="row row-wait">
								<span aria-hidden="true">◌</span><span>—</span><span>…</span>
								<span>
									no more records after {POLL_CAP_MS / 60_000} minutes
									<button type="button" class="retry" onclick={() => attempt++}>Retry</button>
								</span>
							</li>
						{:else if response?.status === 'pending'}
							{@render waitRow('pending · about 60 s')}
						{:else if response?.status === 'partial'}
							{@render waitRow('waiting for more records')}
						{/if}
					</ul>
				</div>
			{:else}
				<div class="stream">
					<div class="stream-label">Live facts · this turn's events · click any row for the full record</div>
					<ul class="rows">
						{#each factRows as row (row.key)}
							{@render recordRow(row)}
						{:else}
							{#if turn === undefined || !turn.done}
								{@render waitRow('waiting for this answer’s events')}
							{:else}
								<li class="row row-wait">
									<span aria-hidden="true">◌</span><span>—</span><span>…</span><span>this turn reported no credentials</span>
								</li>
							{/if}
						{/each}
					</ul>
				</div>
			{/if}
		</div>
	{/if}
</section>

<style>
	.audit-card {
		/* The audit-trace purple is this card's own accent (mockup: shield and label). */
		--audit-purple: #6929c4;
		--audit-purple-soft: #f3eeff;

		container-type: inline-size;
		background: var(--ovi-card);
		border: 1px solid var(--ovi-hairline);
		border-radius: var(--ovi-radius-card);
		box-shadow: var(--ovi-card-shadow);
		overflow: hidden;
	}

	.trace-head {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		padding: 12px 16px;
		border: 0;
		background: none;
		font: inherit;
		color: inherit;
		text-align: left;
		cursor: pointer;
	}

	.trace-head.open {
		border-bottom: 1px solid var(--ovi-hairline);
	}

	.trace-head:focus-visible,
	.row:focus-visible,
	.copy:focus-visible,
	.retry:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: -2px;
	}

	.shield {
		flex: none;
		width: 30px;
		height: 30px;
		border-radius: 50%;
		background: var(--audit-purple-soft);
		color: var(--audit-purple);
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.trace-text {
		display: flex;
		flex-direction: column;
		min-width: 0;
	}

	.tlabel {
		font: 600 12px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		color: var(--audit-purple);
	}

	.tmeta {
		font: 12px var(--ovi-font-mono);
		color: var(--ovi-text-helper);
		overflow-wrap: anywhere;
	}

	.ms {
		flex: none;
		margin-left: auto;
		font: 500 12px var(--ovi-font-mono);
		background: rgba(8, 189, 186, 0.12);
		color: var(--ovi-teal-deep);
		border-radius: var(--ovi-radius-pill);
		padding: 3px 9px;
	}

	.trace-body {
		padding: 16px 18px;
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.panels {
		display: grid;
		grid-template-columns: repeat(2, minmax(0, 1fr));
		gap: 12px;
	}

	.panel {
		background: var(--ovi-surface-bg);
		border-radius: 10px;
		padding: 12px 14px;
		font: 12.5px/1.7 var(--ovi-font-mono);
		min-width: 0;
	}

	.panel-head {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 8px;
		margin-bottom: 4px;
	}

	.panel-title {
		display: block;
		font: 600 11px var(--ovi-font-condensed);
		letter-spacing: 0.1em;
		text-transform: uppercase;
	}

	.panel > .panel-title {
		margin-bottom: 4px;
	}

	.title-ivia {
		color: var(--ovi-brand-primary);
	}

	.title-vault {
		color: var(--ovi-teal-deep);
	}

	.copy,
	.retry {
		flex: none;
		border: 1px solid var(--ovi-border);
		background: var(--ovi-card);
		border-radius: var(--ovi-radius-pill);
		padding: 2px 10px;
		font: 600 11px var(--ovi-font-condensed);
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--ovi-text-strong);
		cursor: pointer;
	}

	.retry {
		margin-left: 8px;
	}

	.kv {
		display: grid;
		grid-template-columns: 8ch minmax(0, 1fr);
		overflow-wrap: anywhere;
	}

	.k {
		color: var(--ovi-text-helper);
	}

	.checks {
		display: grid;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		gap: 10px;
	}

	.check {
		border: 1px solid var(--ovi-ok-border);
		background: var(--ovi-ok-bg);
		border-radius: 10px;
		padding: 11px 13px;
	}

	.check-title {
		font: 600 12px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		color: var(--ovi-ok-text);
	}

	.check p {
		margin: 5px 0 0;
		font-size: 13px;
		line-height: 1.5;
		color: var(--ovi-text-strong);
	}

	.stream-label {
		font: 600 11px var(--ovi-font-condensed);
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--ovi-text-helper);
		margin-bottom: 6px;
	}

	.note {
		background: var(--ovi-amber-soft);
		border-radius: 8px;
		padding: 9px 12px;
		font-size: 13px;
		color: var(--ovi-amber);
		margin-bottom: 6px;
	}

	.rows {
		list-style: none;
		margin: 0;
		padding: 0;
		font: 12.5px var(--ovi-font-mono);
	}

	.row {
		display: grid;
		grid-template-columns: 22px 110px 90px minmax(0, 1fr);
		gap: 8px;
		width: 100%;
		padding: 8px 4px;
		border: 0;
		border-top: 1px solid var(--ovi-hairline);
		background: none;
		font: inherit;
		color: var(--ovi-text-primary);
		text-align: left;
	}

	button.row {
		cursor: pointer;
	}

	button.row:hover {
		background: var(--ovi-surface-bg);
	}

	.what,
	.error-text {
		overflow-wrap: anywhere;
	}

	.when {
		color: var(--ovi-text-helper);
	}

	.src-agent {
		color: var(--audit-purple);
	}

	.src-vault {
		color: var(--ovi-teal-deep);
	}

	.src-postgres {
		color: var(--ovi-brand-primary);
	}

	.src-ivia {
		color: var(--ovi-brand-deep);
	}

	.src-kubernetes {
		color: var(--ovi-text-strong);
	}

	.src-sts {
		color: var(--ovi-amber);
	}

	.row-wait {
		color: var(--ovi-text-muted);
	}

	.row-error {
		color: var(--ovi-red);
	}

	.record {
		display: grid;
		grid-template-columns: max-content minmax(0, 1fr);
		gap: 2px 14px;
		margin: 0 0 8px 34px;
		padding: 10px 12px;
		background: var(--ovi-surface-bg);
		border-radius: 8px;
		font: 12px/1.6 var(--ovi-font-mono);
	}

	.record dt {
		color: var(--ovi-text-helper);
	}

	.record dd {
		margin: 0;
		overflow-wrap: anywhere;
	}

	@container (max-width: 560px) {
		.panels,
		.checks {
			grid-template-columns: minmax(0, 1fr);
		}

		.row {
			grid-template-columns: 14px 62px 64px minmax(0, 1fr);
			gap: 6px;
		}

		.record {
			grid-template-columns: minmax(0, 1fr);
			gap: 0;
			margin-left: 0;
		}

		.record dd {
			margin-bottom: 4px;
		}
	}
</style>
