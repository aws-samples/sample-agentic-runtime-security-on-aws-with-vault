<script lang="ts">
	// Carbon's all.css reads its colours from --cds-* custom properties (theme="g10" is set
	// on <html> in app.html). app.css is imported after it and re-points those tokens at
	// the OscarVault palette.
	import 'carbon-components-svelte/css/all.css';
	import '../app.css';

	import { page } from '$app/state';
	import { getPersona } from '$lib/personas';
	import type { LayoutData } from './$types';

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	let signedIn = $derived(Boolean(data.accessToken));
	let persona = $derived(getPersona(data.sub));
	let displayName = $derived(persona?.fullName ?? data.displayName);
	let initials = $derived(
		displayName
			.split(/\s+/)
			.filter(Boolean)
			.map((word) => word[0])
			.filter((_, i, all) => i === 0 || i === all.length - 1)
			.join('')
			.toUpperCase()
	);

	const links = [
		{ href: '/dashboard', label: 'Dashboard' },
		{ href: '/ask', label: 'Ask' },
		{ href: '/about-me', label: 'About Me' }
	];

	function isCurrent(href: string): boolean {
		const path = page.url.pathname;
		return path === href || path.startsWith(`${href}/`);
	}
</script>

<a class="skip-link" href="#main-content">Skip to main content</a>

<div class="shell">
	<nav class="shell-nav" aria-label="Main">
		{#if signedIn}
			<a class="brand" href="/dashboard" data-sveltekit-reload>
				<span class="brand-mark" aria-hidden="true">OVI</span>
				<span class="brand-text">
					<span class="brand-name">OscarVault</span>
					<span class="brand-sub">International</span>
				</span>
			</a>
		{:else}
			<div class="brand">
				<span class="brand-mark" aria-hidden="true">OVI</span>
				<span class="brand-text">
					<span class="brand-name">OscarVault</span>
					<span class="brand-sub">International</span>
				</span>
			</div>
		{/if}

		<!-- No search feature exists yet: the field is shown, labelled and disabled. -->
		<form class="nav-search" role="search" onsubmit={(e) => e.preventDefault()}>
			<label class="visually-hidden" for="nav-search-input">Search accounts or transactions</label>
			<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
				<circle cx="7" cy="7" r="5"></circle>
				<path d="M11 11l3.5 3.5"></path>
			</svg>
			<input id="nav-search-input" type="search" placeholder="Search accounts or transactions" disabled />
		</form>

		<ul class="nav-links">
			{#each links as link (link.href)}
				<li>
					<!-- Full page loads, as before: each page starts a fresh chat session. -->
					<a
						href={link.href}
						aria-current={isCurrent(link.href) ? 'page' : undefined}
						data-sveltekit-reload
					>
						{link.label}
					</a>
				</li>
			{/each}
		</ul>

		<div class="nav-me">
			{#if signedIn}
				<div class="me-row">
					<span class="me-avatar" aria-hidden="true">{initials}</span>
					<div class="me-text">
						<p class="me-name">{displayName}</p>
						{#if persona}
							<p class="me-role">{persona.role}</p>
						{/if}
					</div>
				</div>
				<p class="me-note">Signed in with IBM Verify Identity Access</p>
				<!-- GET /logout clears the session cookies and ends the IVIA WebSEAL session.
				     data-sveltekit-reload makes this a full navigation that SvelteKit never
				     preloads, so hovering the link cannot sign anyone out. -->
				<a class="me-action" href="/logout" data-sveltekit-reload>Log out</a>
			{:else}
				<div class="me-row">
					<span class="me-avatar me-avatar-anon" aria-hidden="true">—</span>
					<div class="me-text">
						<p class="me-name me-name-anon">Not signed in</p>
						<p class="me-role">Public page</p>
					</div>
				</div>
				<p class="me-note">Use Case 1 needs no sign-in</p>
				<a class="me-action" href="/" data-sveltekit-reload>Sign in</a>
			{/if}
		</div>
	</nav>

	<main id="main-content" class="shell-main" tabindex="-1">
		{@render children()}
	</main>
</div>

<style>
	.shell {
		display: flex;
		min-height: 100vh;
		min-height: 100dvh;
		background: var(--ovi-surface-bg);
	}

	/* ---- Left navigation ---------------------------------------------------------- */
	.shell-nav {
		position: sticky;
		top: 0;
		width: 280px;
		height: 100vh;
		height: 100dvh;
		flex-shrink: 0;
		display: flex;
		flex-direction: column;
		overflow-y: auto;
		background: var(--ovi-nav-bg);
		border-right: 1px solid var(--ovi-hairline);
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 14px;
		margin: 0 24px;
		padding: 28px 0 22px;
		border-bottom: 1px solid var(--ovi-hairline-strong);
		color: var(--ovi-text-primary);
		text-decoration: none;
	}
	a.brand:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
		border-radius: 4px;
	}

	.brand-mark {
		width: 40px;
		height: 40px;
		flex-shrink: 0;
		border-radius: 10px;
		background: var(--ovi-brand-primary);
		color: #ffffff;
		display: flex;
		align-items: center;
		justify-content: center;
		font: 600 14px var(--ovi-font-mono);
	}

	.brand-text {
		display: flex;
		flex-direction: column;
	}

	.brand-name {
		font-weight: 600;
		font-size: 19px;
		line-height: 1.2;
	}

	.brand-sub {
		margin-top: 3px;
		font: 500 11px var(--ovi-font-mono);
		letter-spacing: 0.14em;
		text-transform: uppercase;
		color: var(--ovi-nav-text);
	}

	.nav-search {
		margin: 20px 24px 10px;
		height: 44px;
		box-sizing: border-box;
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 0 16px;
		border-radius: var(--ovi-radius-pill);
		background: var(--ovi-surface-bg);
		border: 1px solid var(--ovi-hairline-strong);
		color: var(--ovi-text-helper);
	}

	.nav-search svg {
		flex-shrink: 0;
	}

	.nav-search input {
		flex: 1;
		min-width: 0;
		border: 0;
		padding: 0;
		background: transparent;
		font: 15px var(--ovi-font-sans);
		color: var(--ovi-text-primary);
		text-overflow: ellipsis;
	}

	.nav-search input::placeholder {
		color: var(--ovi-text-helper);
		opacity: 1;
	}

	.nav-search input:disabled {
		cursor: not-allowed;
	}

	.nav-links {
		display: flex;
		flex-direction: column;
		gap: 2px;
		margin: 0;
		padding: 6px 24px;
		list-style: none;
	}

	.nav-links a {
		display: block;
		padding: 10px 0;
		font-size: 17px;
		color: var(--ovi-text-strong);
		text-decoration: none;
	}

	.nav-links a:hover {
		color: var(--ovi-nav-link-active);
		text-decoration: underline;
	}

	.nav-links a:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
		border-radius: 4px;
	}

	.nav-links a[aria-current='page'] {
		color: var(--ovi-nav-link-active);
		font-weight: 500;
	}

	.nav-me {
		margin-top: auto;
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 18px 24px 22px;
		border-top: 1px solid var(--ovi-hairline-strong);
	}

	.me-row {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.me-avatar {
		width: 44px;
		height: 44px;
		flex-shrink: 0;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ovi-amber-soft);
		color: var(--ovi-amber);
		font-weight: 600;
		font-size: 15px;
	}

	.me-avatar-anon {
		background: var(--ovi-neutral-soft);
		color: var(--ovi-text-secondary);
	}

	.me-text {
		min-width: 0;
	}

	.me-name {
		margin: 0;
		font-weight: 600;
		font-size: 16px;
		color: var(--ovi-nav-amber);
		overflow-wrap: anywhere;
	}

	.me-name-anon {
		color: var(--ovi-text-strong);
	}

	.me-role,
	.me-note {
		margin: 0;
		font-size: 13px;
		color: var(--ovi-nav-text);
	}

	.me-action {
		align-self: flex-start;
		font-size: 14px;
		font-weight: 500;
		color: var(--ovi-nav-link-active);
		text-decoration: none;
	}

	.me-action:hover {
		text-decoration: underline;
	}

	.me-action:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
		border-radius: 4px;
	}

	/* ---- Main column -------------------------------------------------------------- */
	.shell-main {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
	}

	.shell-main:focus {
		outline: none;
	}

	/* Narrow viewports: the navigation stacks above the page instead of beside it. */
	@media (max-width: 960px) {
		.shell {
			flex-direction: column;
		}

		.shell-nav {
			position: static;
			width: auto;
			height: auto;
			border-right: 0;
			border-bottom: 1px solid var(--ovi-hairline);
		}

		.nav-links {
			flex-direction: row;
			flex-wrap: wrap;
			gap: 0 20px;
		}

		.nav-me {
			margin-top: 0;
		}
	}
</style>
