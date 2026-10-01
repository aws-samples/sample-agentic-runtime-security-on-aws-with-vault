<!--
  ToolResultCard — what one tool call returned, drawn as the approved #65 answer boards draw it:
  a header (title, subtitle, tag), the result as a table of rows or as label/value rows for a
  single record, and a footer naming the credential the tool read it with.

  Everything shown comes from $lib/answer-cards (cardLayout). A value the turn's stream did not
  carry is written "not in the stream", in the boards' style for it, never guessed.
-->
<script lang="ts">
	import type { CardLayout, CardValue, RefundDetails } from '$lib/answer-cards';
	import RefundDetailsModal from './RefundDetailsModal.svelte';

	let { layout }: { layout: CardLayout } = $props();

	/** The refund whose details popup is open, from a Refund row's link. */
	let openRefund: RefundDetails | null = $state(null);
</script>

{#snippet value(v: CardValue)}{#if v === undefined}<span class="nis">not in the stream</span>{:else}{v}{/if}{/snippet}

<div class="card">
	<div class="card-header">
		<div>
			<p class="card-title">{layout.title}</p>
			<p class="card-subtitle">
				{layout.subtitle}{#if layout.code}{' · '}<code>{@render value(layout.code.value)}</code>{/if}
			</p>
		</div>
		<span class="card-tag" class:wait={layout.tone === 'wait'}>{layout.tag}</span>
	</div>
	{#if layout.table}
		<div class="card-scroll">
			<table>
				<thead>
					<tr>
						{#each layout.table.columns as column, c (c)}
							<th scope="col" class:r={column.right}>{column.label}</th>
						{/each}
					</tr>
				</thead>
				<tbody>
					{#each layout.table.rows as row, r (r)}
						<tr class:refund-row={layout.table.refundRows?.[r]}>
							{#each row as cell, c (c)}
								{#if cell.value === undefined}
									<td>{@render value(undefined)}</td>
								{:else if cell.refund}
									<td><button type="button" class="refund-link" onclick={() => (openRefund = cell.refund ?? null)}>Refund</button> · {cell.value}</td>
								{:else}
									<td class:mono={cell.style === 'mono'} class:num={cell.style === 'num'}>{cell.value}</td>
								{/if}
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{:else if layout.record}
		<table class="kv">
			<tbody>
				{#each layout.record as row, r (r)}
					<tr>
						<th scope="row">{row.label}</th>
						{#if row.value === undefined}
							<td>{@render value(undefined)}</td>
						{:else}
							<td class="mono">{row.value}</td>
						{/if}
					</tr>
				{/each}
			</tbody>
		</table>
	{/if}
	{#if openRefund}
		<RefundDetailsModal refund={openRefund} onclose={() => (openRefund = null)} />
	{/if}
	<div class="card-footer">
		{#each layout.footer as half, h (h)}
			<span>{#each half as piece, p (p)}{@render value(piece)}{/each}</span>
		{/each}
	</div>
</div>

<style>
	/* The approved boards' card (.card, .cardhd, .ctitle, .csub, .tag, table, table.kv, .cardft, .nis). */
	.card {
		overflow: hidden;
		border-radius: var(--ovi-radius-card);
		border: 1px solid var(--ovi-hairline);
		background: var(--ovi-card);
		box-shadow: var(--ovi-card-shadow);
	}

	.card-header {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 14px 18px;
	}

	/* line-height: normal, as on the boards; Carbon gives <p> and table cells their own. */
	.card-title {
		margin: 0;
		font-weight: 600;
		font-size: 15.5px;
		line-height: normal;
		color: var(--ovi-text-primary);
	}

	.card-subtitle {
		margin: 0;
		font-size: 13px;
		line-height: normal;
		color: var(--ovi-text-helper);
	}

	.card-subtitle code {
		padding: 1px 5px;
		border-radius: 4px;
		background: var(--ovi-surface-bg);
		color: var(--ovi-text-strong);
		font: 12px var(--ovi-font-mono);
	}

	.card-tag {
		margin-left: auto;
		padding: 4px 10px;
		border-radius: var(--ovi-radius-pill);
		background: rgba(8, 189, 186, 0.12);
		color: var(--ovi-teal-deep);
		font: 600 11px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		white-space: nowrap;
	}

	/* A refund waiting for the member's approval. */
	.card-tag.wait {
		background: var(--ovi-amber-soft);
		color: var(--ovi-amber);
	}

	.card-scroll {
		overflow-x: auto;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 14px;
	}

	th {
		padding: 8px 18px;
		background: var(--ovi-surface-bg);
		color: var(--ovi-text-helper);
		font: 600 11px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		text-align: left;
	}

	th.r {
		text-align: right;
	}

	td {
		padding: 11px 18px;
		border-top: 1px solid var(--ovi-hairline);
		color: var(--ovi-text-primary);
		line-height: normal;
	}

	td.mono {
		font: 13px var(--ovi-font-mono);
		color: var(--ovi-text-strong);
		overflow-wrap: anywhere;
	}

	td.num {
		text-align: right;
		font-family: var(--ovi-font-mono);
		white-space: nowrap;
	}

	/* A single record: labels down the left, values beside them. */
	table.kv th {
		width: 170px;
		padding: 11px 18px;
		border-top: 1px solid var(--ovi-hairline);
		vertical-align: top;
	}

	table.kv tr:first-child th,
	table.kv tr:first-child td {
		border-top: 0;
	}

	/* Long lease ids and paths: the two halves wrap onto their own lines rather than being cut. */
	.card-footer {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		gap: 4px 12px;
		padding: 9px 18px;
		border-top: 1px solid var(--ovi-hairline);
		background: var(--ovi-surface-bg);
		font: 12px var(--ovi-font-mono);
		color: var(--ovi-text-helper);
		overflow-wrap: anywhere;
	}

	/* A refund already issued: tinted like the approved status, its amount in green. */
	tr.refund-row td {
		background: var(--ovi-ok-bg);
	}

	tr.refund-row td.num {
		color: #047857;
		font-weight: 600;
	}

	.refund-link {
		padding: 0;
		border: 0;
		background: none;
		cursor: pointer;
		color: var(--ovi-teal-deep);
		font: inherit;
		font-weight: 600;
		text-decoration: underline;
		text-underline-offset: 2px;
	}

	.nis {
		font-style: italic;
		color: var(--ovi-red);
		font-family: var(--ovi-font-sans);
	}
</style>
