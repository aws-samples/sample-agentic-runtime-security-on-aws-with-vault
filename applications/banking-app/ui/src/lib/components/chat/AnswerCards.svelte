<!--
  AnswerCards — the card of every tool call in a turn that returned something drawn
  ($lib/answer-cards), in the order the calls started. get_accounts keeps its own
  AccountsCard, exactly as approved; every other tool is a ToolResultCard.

  No wrapper element: each card lands directly in the answer column, as AccountsCard always has.
-->
<script lang="ts">
	import { cardLayout, type AnswerCardView } from '$lib/answer-cards';
	import AccountsCard from './AccountsCard.svelte';
	import ToolResultCard from './ToolResultCard.svelte';

	interface Props {
		cards: AnswerCardView[];
		/** Whose records they are: the signed-in person's display name. */
		owner?: string;
	}

	let { cards, owner }: Props = $props();
</script>

{#each cards as card (card.key)}
	{#if card.kind === 'get_accounts'}
		<AccountsCard accounts={card.accounts} credential={card.credential} {owner} />
	{:else}
		<ToolResultCard layout={cardLayout(card, owner)} />
	{/if}
{/each}
