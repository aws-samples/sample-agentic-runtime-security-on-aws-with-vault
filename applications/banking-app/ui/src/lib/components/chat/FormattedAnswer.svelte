<!--
  FormattedAnswer — the agent's written answer with its formatting rendered: paragraphs,
  bulleted and numbered lists, and bold, with every account number and dollar amount in bold
  ($lib/answer-format).

  The answer is model output. Every piece of it is written as a text node through Svelte's
  own escaping; there is no {@html} here, so markup in the answer shows as the characters it is.
-->
<script lang="ts">
	import { formatAnswer, type Line, type List } from '$lib/answer-format';

	let { text }: { text: string } = $props();

	const blocks = $derived(formatAnswer(text.trim()));
</script>

{#snippet line(pieces: Line)}{#each pieces as piece}{#if piece.bold}<b>{piece.text}</b>{:else}{piece.text}{/if}{/each}{/snippet}

{#snippet lines(all: Line[])}{#each all as one, i}{#if i > 0}<br />{/if}{@render line(one)}{/each}{/snippet}

{#snippet list(block: List)}
	{#if block.ordered}
		<ol start={block.start}>
			{#each block.items as item}
				<li>{@render lines(item.lines)}{#each item.lists as sub}{@render list(sub)}{/each}</li>
			{/each}
		</ol>
	{:else}
		<ul>
			{#each block.items as item}
				<li>{@render lines(item.lines)}{#each item.lists as sub}{@render list(sub)}{/each}</li>
			{/each}
		</ul>
	{/if}
{/snippet}

<div class="answer">
	{#each blocks as block}
		{#if block.kind === 'paragraph'}
			<p>{@render lines(block.lines)}</p>
		{:else}
			{@render list(block)}
		{/if}
	{/each}
</div>

<style>
	/* The approved board's answer bubble (.ans). */
	.answer {
		padding: 14px 18px;
		border-radius: var(--ovi-radius-card);
		border: 1px solid var(--ovi-hairline);
		background: var(--ovi-card);
		color: var(--ovi-text-primary);
		font-size: 15.5px;
		line-height: 1.6;
		overflow-wrap: anywhere;
	}

	p,
	ol,
	ul {
		margin: 0;
	}

	p + p,
	p + ol,
	p + ul,
	ol + p,
	ul + p,
	ol + ol,
	ul + ul,
	ol + ul,
	ul + ol {
		margin-top: 0.6em;
	}

	ol,
	ul {
		padding-left: 1.5em;
	}

	ol {
		list-style: decimal;
	}

	ul {
		list-style: disc;
	}

	li ol,
	li ul {
		margin-top: 0.2em;
	}

	li + li {
		margin-top: 0.2em;
	}

	/* The board's <b> is the browser's own bold: 700, which the app loads for IBM Plex Sans. */
	b {
		font-weight: 700;
	}
</style>
