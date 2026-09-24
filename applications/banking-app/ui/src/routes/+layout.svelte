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

	// ---- Narrow screens: the navigation is a drawer opened from the top bar ----------
	// Must match the max-width media query in the styles below.
	const NARROW = '(max-width: 960px)';

	let menuOpen = $state(false);

	function closeMenu() {
		menuOpen = false;
	}

	function toggleMenu() {
		menuOpen = !menuOpen;
	}

	// Leaving the narrow layout (a rotated tablet, a widened window) closes the drawer.
	$effect(() => {
		const query = window.matchMedia(NARROW);
		const onChange = () => {
			if (!query.matches) closeMenu();
		};
		query.addEventListener('change', onChange);
		return () => query.removeEventListener('change', onChange);
	});
</script>

<a class="skip-link" href="#main-content">Skip to main content</a>

<div class="shell" class:menu-open={menuOpen}>
	<!-- Top bar, shown only on screens 960px and narrower. -->
	<header class="bar">
		<button
			type="button"
			class="menu-button"
			aria-expanded={menuOpen}
			aria-controls="main-nav"
			aria-label={menuOpen ? 'Close navigation' : 'Open navigation'}
			onclick={toggleMenu}
		>
			{#if menuOpen}
				<svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
					<path d="M5 5l10 10M15 5L5 15"></path>
				</svg>
			{:else}
				<svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
					<path d="M3 6h14M3 10h14M3 14h14"></path>
				</svg>
			{/if}
		</button>
		<span class="bar-mark" aria-hidden="true">OVI</span>
		<span class="bar-name">OscarVault</span>
		{#if signedIn}
			<span class="bar-avatar" role="img" aria-label={displayName}>{initials}</span>
		{/if}
	</header>

	{#if menuOpen}
		<!-- Pointer users close the drawer on the scrim; keyboard users have the menu button. -->
		<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
		<div class="scrim" aria-hidden="true" onclick={closeMenu}></div>
	{/if}

	<!-- The left navigation on wide screens; the drawer on narrow ones. -->
	<nav id="main-nav" class="shell-nav" aria-label="Main">
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

		<ul class="nav-links">
			{#each links as link (link.href)}
				<li>
					<!-- Full page loads, as before: each page starts a fresh chat session. -->
					<a
						href={link.href}
						aria-current={isCurrent(link.href) ? 'page' : undefined}
						data-sveltekit-reload
						onclick={closeMenu}
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
				<a class="me-action" href="/logout" data-sveltekit-reload onclick={closeMenu}>Log out</a>
			{:else}
				<div class="me-row">
					<span class="me-avatar me-avatar-anon" aria-hidden="true">—</span>
					<div class="me-text">
						<p class="me-name me-name-anon">Not signed in</p>
						<p class="me-role">Public page</p>
					</div>
				</div>
				<p class="me-note">Use Case 1 needs no sign-in</p>
				<a class="me-action" href="/" data-sveltekit-reload onclick={closeMenu}>Sign in</a>
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
		/* Carbon's body sets line-height: 1 and 0.16px tracking; the design's navigation uses
		   the font's normal line height and tracking, which spaces the links as drawn. */
		line-height: normal;
		letter-spacing: normal;
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

	.nav-links {
		display: flex;
		flex-direction: column;
		gap: 2px;
		margin: 0;
		padding: 16px 24px 6px;
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

	/* ---- Top bar and drawer (screens 960px and narrower) --------------------------- */
	.bar,
	.scrim {
		display: none;
	}

	@media (max-width: 960px) {
		.shell {
			flex-direction: column;
		}

		.bar {
			position: sticky;
			top: 0;
			z-index: 30;
			box-sizing: border-box;
			height: var(--ovi-bar-height);
			flex-shrink: 0;
			display: flex;
			align-items: center;
			gap: 12px;
			padding: 0 16px;
			background: var(--ovi-nav-bg);
			border-bottom: 1px solid var(--ovi-hairline-strong);
			color: var(--ovi-text-primary);
			line-height: normal;
			letter-spacing: normal;
		}

		.menu-button {
			box-sizing: border-box;
			width: 44px;
			height: 44px;
			flex-shrink: 0;
			padding: 0;
			border: 1px solid var(--ovi-border);
			border-radius: 12px;
			display: flex;
			align-items: center;
			justify-content: center;
			background: var(--ovi-card);
			color: var(--ovi-text-primary);
			cursor: pointer;
		}

		.menu-button:focus-visible {
			outline: var(--ovi-focus-ring);
			outline-offset: 2px;
		}

		.bar-mark {
			width: 34px;
			height: 34px;
			flex-shrink: 0;
			border-radius: 9px;
			background: var(--ovi-brand-primary);
			color: #ffffff;
			display: flex;
			align-items: center;
			justify-content: center;
			font: 600 12px var(--ovi-font-mono);
		}

		.bar-name {
			font-weight: 600;
			font-size: 17px;
			line-height: 1.2;
		}

		.bar-avatar {
			width: 36px;
			height: 36px;
			flex-shrink: 0;
			margin-left: auto;
			border-radius: 50%;
			display: flex;
			align-items: center;
			justify-content: center;
			background: var(--ovi-amber-soft);
			color: var(--ovi-amber);
			font-weight: 600;
			font-size: 13px;
		}

		/* The navigation becomes a drawer under the bar, off screen and hidden from
		   assistive technology and the Tab order (visibility: hidden) until opened. */
		.shell-nav {
			position: fixed;
			top: var(--ovi-bar-height);
			bottom: 0;
			left: 0;
			z-index: 20;
			box-sizing: border-box;
			width: 300px;
			max-width: 100%;
			height: auto;
			border-right: 0;
			box-shadow: 4px 0 24px rgba(22, 22, 22, 0.18);
			transform: translateX(-100%);
			visibility: hidden;
			transition:
				transform 0.2s ease,
				visibility 0s linear 0.2s;
		}

		.menu-open .shell-nav {
			transform: none;
			visibility: visible;
			transition:
				transform 0.2s ease,
				visibility 0s linear 0s;
		}

		/* The bar carries the brand here. */
		.shell-nav .brand {
			display: none;
		}

		.nav-links {
			padding: 12px 24px;
		}

		.me-action {
			font-size: 15px;
		}

		.scrim {
			display: block;
			position: fixed;
			inset: var(--ovi-bar-height) 0 0 0;
			z-index: 10;
			background: var(--ovi-scrim);
		}
	}

	@media (max-width: 960px) and (prefers-reduced-motion: reduce) {
		.shell-nav,
		.menu-open .shell-nav {
			transition: none;
		}
	}
</style>
