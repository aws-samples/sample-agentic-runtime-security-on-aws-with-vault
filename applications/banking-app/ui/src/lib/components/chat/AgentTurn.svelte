<!--
  AgentTurn — one agent reply: a round agent icon beside a column of tool chips, cards and
  the answer. `label` names the agent for screen readers ("Banking Agent: ...").
-->
<script lang="ts">
	import type { Snippet } from 'svelte';

	interface Props {
		label: string;
		/** Glyph inside the round icon. Decorative. */
		icon: Snippet;
		children: Snippet;
	}

	let { label, icon, children }: Props = $props();
</script>

<div class="agent-turn">
	<span class="agent-icon" aria-hidden="true">{@render icon()}</span>
	<div class="agent-column">
		<span class="visually-hidden">{label}: </span>
		{@render children()}
	</div>
</div>

<style>
	.agent-turn {
		display: flex;
		align-items: flex-start;
		gap: 12px;
	}

	.agent-icon {
		width: 34px;
		height: 34px;
		flex-shrink: 0;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ovi-nav-bg);
		color: var(--ovi-brand-primary);
	}

	.agent-column {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	/* Carbon's inline notification (used for errors) sized to the column. */
	.agent-column :global(.bx--inline-notification) {
		max-width: none;
		margin: 0;
		border-radius: var(--ovi-radius-card);
		overflow: hidden;
	}
</style>
