<script lang="ts">
	import '../app.css';
	import type { LayoutData } from './$types';

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();
</script>

<div class="app-shell">
	{#if data.accessToken}
		<header class="app-header">
			<div class="container header-inner">
				<div class="brand">
					<span class="brand-icon">🏦</span>
					<span class="brand-name">CDL Bank</span>
					<span class="brand-badge">Agentic Runtime Security Demo</span>
				</div>
				<nav class="header-nav">
					<a href="/dashboard" data-sveltekit-reload>Dashboard</a>
					<button class="btn btn-secondary" onclick={() => { window.location.href = '/logout'; }}>Logout</button>
				</nav>
			</div>
		</header>
	{/if}

	<main class="main-content">
		{@render children()}
	</main>
</div>

<style>
	.app-shell {
		min-height: 100vh;
		display: flex;
		flex-direction: column;
	}

	.app-header {
		background: #161616;
		padding: 0.75rem 0;
		position: sticky;
		top: 0;
		z-index: 100;
	}

	.header-inner {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}

	.brand-icon {
		font-size: 1.5rem;
	}

	.brand-name {
		font-size: 1.1rem;
		font-weight: 600;
		color: #ffffff;
	}

	.brand-badge {
		font-size: 0.7rem;
		background: #0f62fe;
		color: #ffffff;
		padding: 0.15rem 0.5rem;
		border-radius: 999px;
		font-weight: 600;
	}

	.header-nav {
		display: flex;
		align-items: center;
		gap: 1.5rem;
	}

	.header-nav a {
		font-size: 0.875rem;
		color: #c6c6c6;
		font-weight: 500;
	}

	.header-nav a:hover {
		color: #ffffff;
		text-decoration: none;
	}

	.header-nav :global(.btn-secondary) {
		background: #393939;
		color: #ffffff;
		font-size: 0.8rem;
	}

	.header-nav :global(.btn-secondary:hover) {
		background: #525252;
	}

	.main-content {
		flex: 1;
		padding: 2rem 0;
	}
</style>
