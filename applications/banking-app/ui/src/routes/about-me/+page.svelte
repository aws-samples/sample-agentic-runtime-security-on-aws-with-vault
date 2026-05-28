<script lang="ts">
	import { getPersona } from '$lib/personas';
	import type { LayoutData } from '../$types';

	let { data }: { data: LayoutData } = $props();

	let persona = $derived(getPersona(data.sub));
</script>

<svelte:head>
	<title>About Me — OscarVault International</title>
</svelte:head>

<section class="about-me-page">
	{#if persona}
		<header class="about-me-header">
			<img class="about-me-avatar" src={persona.avatar} alt={persona.fullName} />
			<div class="about-me-headline">
				<h1>{persona.fullName}</h1>
				<p class="about-me-tagline">{persona.tagline}</p>
			</div>
		</header>

		<article class="about-me-body">
			{#each persona.backstory as paragraph}
				<p>{paragraph}</p>
			{/each}

			{#if persona.wikipediaUrl}
				<p class="about-me-wiki">
					<a href={persona.wikipediaUrl} target="_blank" rel="noopener noreferrer">
						Read more on Wikipedia &rarr;
					</a>
				</p>
			{/if}
		</article>
	{:else}
		<div class="about-me-empty">
			<h1>No profile available</h1>
			<p>
				The current user ({data.sub || 'unknown'}) does not have a workshop persona
				configured. Sign in as <code>oscar</code> or <code>jaime</code> to see a profile.
			</p>
		</div>
	{/if}
</section>

<style>
	.about-me-page {
		max-width: 720px;
		margin: 2rem auto;
		padding: 0 1rem;
		color: var(--cds-text-01, #161616);
	}

	.about-me-header {
		display: flex;
		align-items: center;
		gap: 1.5rem;
		margin-bottom: 2rem;
	}

	.about-me-avatar {
		width: 160px;
		height: 160px;
		border-radius: 50%;
		object-fit: cover;
		flex-shrink: 0;
		box-shadow: 0 0 0 2px rgba(0, 0, 0, 0.12);
	}

	.about-me-headline h1 {
		margin: 0 0 0.25rem;
		font-size: 2rem;
		font-weight: 400;
		line-height: 1.2;
	}

	.about-me-tagline {
		margin: 0;
		font-size: 1rem;
		color: var(--cds-text-02, #525252);
	}

	.about-me-body p {
		font-size: 1rem;
		line-height: 1.6;
		margin: 0 0 1.25rem;
	}

	.about-me-wiki {
		margin-top: 1.5rem;
	}

	.about-me-wiki a {
		color: var(--cds-link-01, #0f62fe);
		text-decoration: none;
		font-weight: 500;
	}

	.about-me-wiki a:hover {
		text-decoration: underline;
	}

	.about-me-empty {
		text-align: center;
		padding: 3rem 1rem;
	}

	.about-me-empty code {
		background: var(--cds-layer-01, #f4f4f4);
		padding: 0.125rem 0.375rem;
		border-radius: 2px;
		font-size: 0.95em;
	}
</style>
