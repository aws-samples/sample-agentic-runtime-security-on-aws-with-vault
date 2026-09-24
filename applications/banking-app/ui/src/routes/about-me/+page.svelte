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
			<img class="about-me-avatar" src={persona.avatar} alt={`Portrait of ${persona.fullName}`} />
			<div class="about-me-headline">
				<p class="about-me-eyebrow">About Me</p>
				<h1>{persona.fullName}</h1>
				<p class="about-me-tagline">{persona.tagline}</p>
			</div>
		</header>

		<article class="about-me-card">
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
		<div class="about-me-card about-me-empty">
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
		width: 100%;
		max-width: 760px;
		box-sizing: border-box;
		margin: 0 auto;
		padding: 48px 32px;
		color: var(--ovi-text-primary);
	}

	.about-me-header {
		display: flex;
		align-items: center;
		gap: 24px;
		margin-bottom: 28px;
	}

	.about-me-avatar {
		width: 120px;
		height: 120px;
		flex-shrink: 0;
		border-radius: 50%;
		object-fit: cover;
		border: 4px solid var(--ovi-card);
		box-shadow: 0 6px 24px rgba(22, 22, 22, 0.08);
	}

	.about-me-eyebrow {
		margin: 0;
		font: 600 12px var(--ovi-font-condensed);
		letter-spacing: 0.12em;
		text-transform: uppercase;
		color: var(--ovi-teal-deep);
	}

	.about-me-headline h1 {
		margin: 4px 0;
		font-size: 28px;
		font-weight: 600;
		line-height: 1.2;
	}

	.about-me-tagline {
		margin: 0;
		font-size: 15px;
		color: var(--ovi-text-secondary);
	}

	.about-me-card {
		padding: 24px 28px;
		border-radius: var(--ovi-radius-card-lg);
		border: 1px solid var(--ovi-hairline);
		background: var(--ovi-card);
		box-shadow: var(--ovi-card-shadow);
	}

	.about-me-card p {
		margin: 0 0 1.25rem;
		font-size: 16px;
		line-height: 1.6;
		color: var(--ovi-text-strong);
	}

	.about-me-card p:last-child {
		margin-bottom: 0;
	}

	.about-me-wiki a {
		color: var(--ovi-brand-primary);
		font-weight: 500;
		text-decoration: none;
	}

	.about-me-wiki a:hover {
		color: var(--ovi-brand-deep);
		text-decoration: underline;
	}

	.about-me-wiki a:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
		border-radius: 4px;
	}

	.about-me-empty {
		text-align: center;
	}

	.about-me-empty h1 {
		margin: 0 0 12px;
		font-size: 22px;
		font-weight: 600;
	}

	.about-me-empty code {
		padding: 0.125rem 0.375rem;
		border-radius: 4px;
		background: var(--ovi-surface-bg);
		font-family: var(--ovi-font-mono);
		font-size: 0.95em;
	}

	@media (max-width: 600px) {
		.about-me-page {
			padding: 32px 16px;
		}

		.about-me-header {
			flex-direction: column;
			align-items: flex-start;
		}
	}
</style>
