<!-- AnswerCard — the agent's written answer. `pending` is the "Thinking…" placeholder. -->
<script lang="ts">
	import type { Snippet } from 'svelte';

	let { pending = false, children }: { pending?: boolean; children: Snippet } = $props();
</script>

<div class="answer" class:answer-pending={pending}>{@render children()}</div>

<style>
	.answer {
		padding: 14px 18px;
		border-radius: var(--ovi-radius-card);
		border: 1px solid var(--ovi-hairline);
		background: var(--ovi-card);
		box-shadow: var(--ovi-card-shadow);
		color: var(--ovi-text-primary);
		font-size: 15.5px;
		line-height: 1.6;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}

	.answer-pending {
		color: var(--ovi-text-helper);
		font-style: italic;
	}
</style>
