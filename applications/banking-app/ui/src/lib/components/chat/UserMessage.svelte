<!-- UserMessage — the member's own message, right-aligned. -->
<script lang="ts">
	import type { Snippet } from 'svelte';

	let { children }: { children: Snippet } = $props();
</script>

<div class="user-message"><span class="visually-hidden">You: </span>{@render children()}</div>

<style>
	.user-message {
		align-self: flex-end;
		max-width: min(75%, 640px);
		padding: 11px 16px;
		border-radius: var(--ovi-radius-bubble);
		border: 1px solid var(--ovi-user-bubble-border);
		background: var(--ovi-user-bubble);
		color: var(--ovi-text-primary);
		font-size: 15.5px;
		line-height: 1.5;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}
</style>
