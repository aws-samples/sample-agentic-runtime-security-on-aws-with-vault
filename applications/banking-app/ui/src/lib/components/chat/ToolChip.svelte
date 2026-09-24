<!--
  ToolChip — one step the agent took, as a mono pill: "✓ get_accounts · 212 ms".

  `status` and `detail` are optional; pass them only when the agent's stream reports them.
    done    → green tick
    waiting → amber ring (e.g. waiting for the member's approval)
-->
<script lang="ts">
	interface Props {
		label: string;
		status?: 'done' | 'waiting';
		detail?: string;
	}

	let { label, status, detail }: Props = $props();
</script>

<span class="tool-chip" class:tool-chip-waiting={status === 'waiting'}>
	{#if status === 'done'}
		<span class="tool-done" aria-hidden="true">✓</span><span class="visually-hidden">Completed: </span>
	{:else if status === 'waiting'}
		<span aria-hidden="true">◌</span><span class="visually-hidden">Waiting: </span>
	{/if}
	<span>{label}</span>
	{#if detail}
		<span class="tool-detail">· {detail}</span>
	{/if}
</span>

<style>
	.tool-chip {
		align-self: flex-start;
		display: inline-flex;
		align-items: center;
		gap: 8px;
		max-width: 100%;
		padding: 6px 12px;
		border-radius: var(--ovi-radius-pill);
		border: 1px solid var(--ovi-hairline-strong);
		background: var(--ovi-card);
		color: var(--ovi-text-strong);
		font: 500 13px var(--ovi-font-mono);
		overflow-wrap: anywhere;
	}

	.tool-chip-waiting {
		color: var(--ovi-amber);
	}

	.tool-done {
		color: var(--ovi-ok-text);
	}

	.tool-detail {
		color: var(--ovi-text-helper);
	}
</style>
