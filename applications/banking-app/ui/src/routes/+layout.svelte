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
					<span class="brand-badge">Workshop Demo</span>
				</div>
				<nav class="header-nav">
					<a href="/dashboard">Dashboard</a>
					<a href="/logout" class="btn btn-secondary">Logout</a>
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
		background: #fff;
		border-bottom: 1px solid var(--color-border);
		padding: 0.75rem 0;
		position: sticky;
		top: 0;
		z-index: 100;
		box-shadow: 0 1px 4px rgba(0, 0, 0, 0.06);
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
		font-weight: 700;
		color: var(--color-text);
	}

	.brand-badge {
		font-size: 0.7rem;
		background: #dbeafe;
		color: #1e40af;
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
		font-size: 0.9rem;
		color: var(--color-text-secondary);
		font-weight: 500;
	}

	.header-nav a:hover {
		color: var(--color-primary);
		text-decoration: none;
	}

	.main-content {
		flex: 1;
		padding: 2rem 0;
	}
</style>
