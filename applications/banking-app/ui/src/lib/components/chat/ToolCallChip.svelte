<!--
  ToolCallChip — one tool call of the turn, as the approved board draws it: "✓ get_accounts · 0.4s".

    in_progress → a pending mark and the tool name, no duration yet
    success     → green tick, then the time from the call's start to its result
    error       → ✕, then the time the call took before it failed
-->
<script lang="ts">
	import type { ToolCallStatus } from '$lib/agent-events';
	import { formatDuration } from '$lib/accounts-turn';

	interface Props {
		name: string;
		status: ToolCallStatus;
		durationMs?: number;
	}

	let { name, status, durationMs }: Props = $props();
</script>

<span class="tchip">
	{#if status === 'success'}
		<span class="tok" aria-hidden="true">✓</span><span class="visually-hidden">Completed: </span>
	{:else if status === 'error'}
		<span class="tfail" aria-hidden="true">✕</span><span class="visually-hidden">Failed: </span>
	{:else}
		<span class="trun" aria-hidden="true">◌</span><span class="visually-hidden">Running: </span>
	{/if}
	<span>{name}</span>
	{#if status !== 'in_progress' && durationMs !== undefined}
		<span class="dur">· {formatDuration(durationMs)}</span>
	{/if}
</span>

<style>
	/* The approved board's tool chip (.tchip, .tok, .dur). */
	.tchip {
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

	.tok {
		color: var(--ovi-ok-text);
	}

	.tfail {
		color: var(--ovi-red);
	}

	.trun,
	.dur {
		color: var(--ovi-text-helper);
	}
</style>
