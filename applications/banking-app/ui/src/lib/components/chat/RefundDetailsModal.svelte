<!--
  RefundDetailsModal — the stored record of one issued refund, opened from the Refund row of the
  Use Case 3 transaction list (Bear's approved mockup, issue #100). Read-only: it shows what
  banking.refunds holds and what it was issued against, and changes nothing. A value the stream
  did not carry is written "not in the stream", never guessed. Esc and the close button dismiss it.
-->
<script lang="ts">
	import { formatAccountType, formatBalance } from '$lib/accounts-turn';
	import type { RefundDetails } from '$lib/answer-cards';

	let { refund, onclose }: { refund: RefundDetails; onclose: () => void } = $props();

	let dialog: HTMLDialogElement | undefined = $state();

	$effect(() => {
		if (dialog && !dialog.open) dialog.showModal();
	});

	const NIS = 'not in the stream';
	const orNis = (v: string | undefined) => (v === undefined || v === '' ? NIS : v);
	const approvedAt = $derived(refund.approvedAt ? `${refund.approvedAt.slice(0, 19)} UTC` : undefined);
	const amount = $derived(refund.amount === undefined ? undefined : formatBalance(refund.amount));
	const charge = $derived(
		[refund.chargeDescription, refund.chargeMerchant, refund.chargeAmount === undefined ? undefined : formatBalance(refund.chargeAmount)]
			.filter((part) => part !== undefined && part !== '')
			.join(' · ')
	);
	const account = $derived(
		[refund.accountId, refund.accountType === undefined ? undefined : formatAccountType(refund.accountType)]
			.filter((part) => part !== undefined && part !== '')
			.join(' · ')
	);
</script>

<dialog bind:this={dialog} class="modal" aria-label="Refund details" onclose={onclose} onclick={(e) => e.target === dialog && dialog?.close()}>
	<div class="mh">
		<h3>Refund details</h3>
		<span class="mh-right">
			<span class="pill"><i></i>Approved</span>
			<button class="x" type="button" aria-label="Close" onclick={() => dialog?.close()}>&times;</button>
		</span>
	</div>
	<div class="hero">
		<div class="amt">{amount === undefined ? NIS : `+${amount}`} <small>{refund.currency ?? ''}</small></div>
		<div class="who">approved by <b>{orNis(refund.approvedBy)}</b>{#if approvedAt} · {approvedAt}{/if}</div>
	</div>
	<div class="grp">
		<h4>The refund</h4>
		<div class="row"><span>Refund id</span><code>{orNis(refund.refundId)}</code></div>
		<div class="row"><span>Approved by</span><code>{orNis(refund.approvedBy)}</code></div>
	</div>
	<div class="grp">
		<h4>What was refunded</h4>
		<div class="row"><span>Charge</span><code>{orNis(charge)}</code></div>
		<div class="row"><span>Charge id</span><code>{orNis(refund.chargeId)}</code></div>
		<div class="row"><span>Account</span><code>{orNis(account)}</code></div>
	</div>
	<div class="grp">
		<h4>Audit trail</h4>
		<div class="row"><span>Request id</span><code>{orNis(refund.requestId)}</code></div>
	</div>
	<div class="mf">Read-only record. Close with &times; or Esc.</div>
</dialog>

<style>
	.modal {
		width: min(580px, calc(100vw - 32px));
		padding: 0;
		border: 1px solid var(--ovi-hairline-strong);
		border-radius: var(--ovi-radius-card-lg);
		background: var(--ovi-card);
		color: var(--ovi-text-primary);
		box-shadow: 0 8px 28px rgba(0, 45, 156, 0.18);
		overflow: hidden;
	}
	.modal::backdrop {
		background: rgba(22, 22, 22, 0.4);
	}
	.mh {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 12px;
		padding: 14px 16px;
		background: var(--ovi-nav-bg);
	}
	.mh h3 {
		margin: 0;
		font-size: 16px;
		color: var(--ovi-brand-deep);
	}
	.mh-right {
		display: inline-flex;
		align-items: center;
		gap: 8px;
	}
	.pill {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 3px 10px;
		border-radius: var(--ovi-radius-pill);
		background: var(--ovi-ok-bg);
		border: 1px solid var(--ovi-ok-border);
		color: var(--ovi-ok-text);
		font-size: 12px;
		font-weight: 600;
		white-space: nowrap;
	}
	.pill i {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--ovi-ok-dot);
	}
	.x {
		border: 0;
		background: none;
		cursor: pointer;
		color: var(--ovi-text-helper);
		font: 600 20px/1 system-ui;
		padding: 0 4px;
	}
	.hero {
		display: flex;
		justify-content: space-between;
		align-items: baseline;
		flex-wrap: wrap;
		gap: 12px;
		padding: 16px 16px 12px;
		border-bottom: 1px solid var(--ovi-hairline-strong);
	}
	.amt {
		font: 600 28px/1.1 var(--ovi-font-sans);
		color: #059669;
		font-variant-numeric: tabular-nums;
	}
	.amt small {
		font-size: 13px;
		font-weight: 500;
		color: var(--ovi-text-helper);
	}
	.who {
		font-size: 13px;
		color: var(--ovi-text-helper);
	}
	.who b {
		font-weight: 500;
		color: var(--ovi-text-strong);
	}
	.grp {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 12px 16px 4px;
		min-width: 0;
	}
	.grp + .grp {
		border-top: 1px solid var(--ovi-hairline-strong);
	}
	.grp h4 {
		margin: 0 0 4px;
		font: 600 11px/1 var(--ovi-font-mono);
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--ovi-text-helper);
	}
	.row {
		display: grid;
		grid-template-columns: 110px 1fr;
		gap: 12px;
		align-items: baseline;
		padding-bottom: 8px;
	}
	.row span {
		font: 12.5px/1.6 var(--ovi-font-mono);
		color: var(--ovi-text-helper);
	}
	.row code {
		font: 12.5px/1.6 var(--ovi-font-mono);
		color: var(--ovi-text-strong);
		overflow-wrap: anywhere;
	}
	.mf {
		padding: 10px 16px;
		background: var(--ovi-control-bg);
		border-top: 1px solid var(--ovi-hairline-strong);
		font-size: 12.5px;
		color: var(--ovi-text-helper);
	}
	@media (max-width: 480px) {
		.row {
			grid-template-columns: 1fr;
			gap: 0;
		}
	}
</style>
