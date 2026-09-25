<script lang="ts">
	// Carbon's all.css reads its colours from --cds-* custom properties (theme="g10" is set
	// on <html> in app.html). app.css is imported after it and re-points those tokens at
	// the OscarVault palette.
	import 'carbon-components-svelte/css/all.css';
	import '../app.css';

	import { tick } from 'svelte';
	import { browser } from '$app/environment';
	import { page } from '$app/state';
	import { getPersona } from '$lib/personas';
	import { HEAD_SCRIPT, isMarkedCollapsed, setCollapsed } from '$lib/nav-rail';
	import PersonaMenu from '$lib/components/nav/PersonaMenu.svelte';
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

	// ---- Wide screens: the navigation collapses to a 72px icon rail -----------------
	// The rail is drawn by CSS from an attribute on <html> that the head script sets before
	// the first paint ($lib/nav-rail), so the markup is the same in both states and this
	// state only drives the toggle's aria-expanded. On screens 960px and narrower the rail
	// does not apply: the navigation is the drawer below, whatever was chosen here.
	let collapsed = $state(browser && isMarkedCollapsed());

	function toggleCollapsed() {
		collapsed = !collapsed;
		setCollapsed(collapsed);
	}

	// Escape hides a rail link's name tooltip without moving focus or the pointer (WCAG
	// 1.4.13). Leaving or blurring the link brings tooltips back.
	let tipsDismissed = $state(false);

	function showingTip(): boolean {
		return Boolean(nav?.querySelector('.nav-links a:hover, .nav-links a:focus-visible'));
	}

	// ---- Narrow screens: the navigation is a drawer opened from the top bar ----------
	// Must match the max-width media query in the styles below.
	const NARROW = '(max-width: 960px)';

	let menuOpen = $state(false);
	let menuButton: HTMLButtonElement | undefined = $state();
	let nav: HTMLElement | undefined = $state();

	// ---- The persona menu: the account button at the foot of the navigation ---------
	// Opens above the account block ($lib/components/nav/PersonaMenu). Escape reaches it
	// through the one window key handler below, before the drawer's own Escape.
	let personaOpen = $state(false);
	let personaMenu: ReturnType<typeof PersonaMenu> | undefined = $state();
	let meBlock: HTMLElement | undefined = $state();

	// Opening moves focus to the drawer's first link. It runs after the DOM update, when the
	// drawer is no longer visibility: hidden and can take focus.
	async function openMenu() {
		menuOpen = true;
		await tick();
		drawerLinks()[0]?.focus();
	}

	// Escape, the scrim and the menu button return focus to the menu button. Following a
	// link does not: the page is navigating away.
	function closeMenu({ returnFocus = true } = {}) {
		if (!menuOpen) return;
		menuOpen = false;
		personaOpen = false;
		if (returnFocus) menuButton?.focus();
	}

	function toggleMenu() {
		if (menuOpen) closeMenu();
		else openMenu();
	}

	// Leaving the narrow layout (a rotated tablet, a widened window) closes the drawer.
	$effect(() => {
		const query = window.matchMedia(NARROW);
		const onChange = () => {
			if (!query.matches) closeMenu({ returnFocus: false });
		};
		query.addEventListener('change', onChange);
		return () => query.removeEventListener('change', onChange);
	});

	// The drawer's links and controls, including the persona menu's scrolling claims tables
	// (tabindex="0"). The desktop brand link stays in the DOM but is display: none here, and
	// an element with no layout box has no client rects.
	function drawerLinks(): HTMLElement[] {
		if (!nav) return [];
		return [
			...nav.querySelectorAll<HTMLElement>('a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])')
		].filter((el) => el.getClientRects().length > 0);
	}

	// What Tab reaches while the drawer is open: the menu button, which closes it, then the
	// drawer's links. The button comes first because it comes first on screen and in the DOM.
	function focusCycle(): HTMLElement[] {
		const links = drawerLinks();
		return menuButton ? [menuButton, ...links] : links;
	}

	// An open persona menu takes Escape first: it closes, and a drawer around it stays open.
	// While the drawer is open: Escape closes it, and Tab / Shift+Tab wrap through the menu
	// button and the drawer.
	function onWindowKeydown(e: KeyboardEvent) {
		if (personaOpen && e.key === 'Escape') {
			e.preventDefault();
			personaMenu?.close();
			return;
		}
		if (!menuOpen) {
			if (e.key === 'Escape' && collapsed && !window.matchMedia(NARROW).matches && showingTip()) {
				tipsDismissed = true;
			}
			return;
		}
		if (e.key === 'Escape') {
			e.preventDefault();
			closeMenu();
			return;
		}
		if (e.key !== 'Tab') return;
		const items = focusCycle();
		if (items.length === 0) return;
		const first = items[0];
		const last = items[items.length - 1];
		const active = document.activeElement;
		const inside = items.includes(active as HTMLElement);
		if (e.shiftKey && (active === first || !inside)) {
			e.preventDefault();
			last.focus();
		} else if (!e.shiftKey && (active === last || !inside)) {
			e.preventDefault();
			first.focus();
		}
	}
</script>

<svelte:window onkeydown={onWindowKeydown} />

<svelte:head>
	<!-- Marks <html> collapsed before the first paint when the viewer chose the rail. -->
	{@html HEAD_SCRIPT}
</svelte:head>

<a class="skip-link" href="#main-content">Skip to main content</a>

<div class="shell" class:menu-open={menuOpen}>
	<!-- Top bar, shown only on screens 960px and narrower. -->
	<header class="bar">
		<button
			bind:this={menuButton}
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
			{#if persona}
				<img class="bar-avatar avatar-photo" src={persona.avatar} alt={displayName} />
			{:else}
				<span class="bar-avatar" role="img" aria-label={displayName}>{initials}</span>
			{/if}
		{/if}
	</header>

	{#if menuOpen}
		<!-- Pointer users close the drawer on the scrim; keyboard users have Escape. -->
		<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
		<div class="scrim" aria-hidden="true" onclick={() => closeMenu()}></div>
	{/if}

	<!-- The left navigation on wide screens; the drawer on narrow ones. -->
	<nav
		id="main-nav"
		class="shell-nav"
		class:tips-dismissed={tipsDismissed}
		class:persona-open={personaOpen}
		aria-label="Main"
		bind:this={nav}
	>
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
					<!-- Full page loads, as before: each page starts a fresh chat session.
					     The icon shows only in the rail. There the label stays the link's name,
					     clipped out of sight, and shows as a tooltip on hover and focus. -->
					<a
						href={link.href}
						aria-current={isCurrent(link.href) ? 'page' : undefined}
						data-sveltekit-reload
						onclick={() => closeMenu({ returnFocus: false })}
						onmouseleave={() => (tipsDismissed = false)}
						onblur={() => (tipsDismissed = false)}
					>
						<svg class="nav-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
							{#if link.href === '/dashboard'}
								<rect x="3" y="3" width="6" height="6" rx="1.5"></rect>
								<rect x="11" y="3" width="6" height="6" rx="1.5"></rect>
								<rect x="3" y="11" width="6" height="6" rx="1.5"></rect>
								<rect x="11" y="11" width="6" height="6" rx="1.5"></rect>
							{:else if link.href === '/ask'}
								<path d="M4 3h9l3 3v11H4z"></path>
								<path d="M7 9h6M7 12h6"></path>
							{:else}
								<circle cx="10" cy="7" r="3.2"></circle>
								<path d="M4 17c1-3.3 3.3-5 6-5s5 1.7 6 5"></path>
							{/if}
						</svg>
						<span class="nav-label">{link.label}</span>
					</a>
				</li>
			{/each}
		</ul>

		<div class="nav-me" class:nav-me-signed-in={signedIn} bind:this={meBlock}>
			{#if signedIn && data.signInClaims}
				<!-- The photo and name open the persona menu: the sign-in tokens' claims, and Log out. -->
				<PersonaMenu
					bind:this={personaMenu}
					bind:open={personaOpen}
					{displayName}
					role={persona?.role}
					avatar={persona?.avatar}
					{initials}
					claims={data.signInClaims}
					anchor={meBlock}
					onnavigate={() => closeMenu({ returnFocus: false })}
				/>
				<p class="me-note">Signed in with IBM Verify Identity Access</p>
			{:else}
				<div class="me-row">
					<span class="me-avatar me-avatar-anon" aria-hidden="true">—</span>
					<div class="me-text">
						<p class="me-name me-name-anon">Not signed in</p>
						<p class="me-role">Public page</p>
					</div>
				</div>
				<p class="me-note">Use Case 1 needs no sign-in</p>
				<a class="me-action" href="/" data-sveltekit-reload onclick={() => closeMenu({ returnFocus: false })}>Sign in</a>
			{/if}
		</div>

		<!-- Collapse / expand, in the navigation's footer as in Carbon's UI Shell side nav.
		     Wide screens only. Both names are in the markup and CSS shows the one that
		     matches the state, so the name is right before the page has started. -->
		<div class="nav-foot">
			<button type="button" class="nav-toggle" aria-expanded={!collapsed} aria-controls="main-nav" onclick={toggleCollapsed}>
				<svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
					<rect x="2.5" y="3.5" width="15" height="13" rx="2"></rect>
					<path d="M7.5 3.5v13"></path>
					<path class="toggle-when-full" d="M13.5 8l-2 2 2 2"></path>
					<path class="toggle-when-rail" d="M11.5 8l2 2-2 2"></path>
				</svg>
				<span class="toggle-when-full">Collapse</span>
				<span class="toggle-when-rail">Expand navigation</span>
			</button>
		</div>
	</nav>

	<!-- While the drawer is open the page behind it is inert: it takes no focus and is not read. -->
	<main id="main-content" class="shell-main" tabindex="-1" inert={menuOpen}>
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

	/* The link icons and the toggle's "Expand" parts belong to the rail only. */
	.nav-icon,
	.toggle-when-rail {
		display: none;
	}

	.nav-me {
		margin-top: auto;
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 18px 24px 22px;
		border-top: 1px solid var(--ovi-hairline-strong);
	}

	/* Signed in, the account is a button (PersonaMenu) and the note lines up with its text. */
	.nav-me-signed-in {
		padding: 14px 16px 18px;
	}

	/* line-height: normal, as drawn; Carbon sets 1.5 on every <p>. */
	.nav-me-signed-in .me-note {
		padding: 0 8px;
		line-height: normal;
	}

	/* Wide screens: while the persona menu is open, the navigation (and the menu inside it)
	   sits over the page's own layers (at most 5) and under a floating panel's scrim (20).
	   The drawer already sits at 20. */
	@media not all and (max-width: 960px) {
		.shell-nav.persona-open {
			z-index: 10;
		}
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

	/* A persona's photo in the account row or the top bar: the avatar circle's size and
	   shape, cropped to fill it the way About Me crops the same photo. */
	.avatar-photo {
		object-fit: cover;
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

	/* ---- Collapse / expand control (wide screens) ---------------------------------- */
	.nav-foot {
		padding: 8px 16px;
		border-top: 1px solid var(--ovi-hairline-strong);
	}

	.nav-toggle {
		box-sizing: border-box;
		width: 100%;
		height: 40px;
		padding: 0 8px;
		border: 0;
		border-radius: 10px;
		display: flex;
		align-items: center;
		gap: 10px;
		background: none;
		color: var(--ovi-text-strong);
		font: 500 14px var(--ovi-font-sans);
		letter-spacing: normal;
		cursor: pointer;
	}

	.nav-toggle:hover {
		background: rgba(15, 98, 254, 0.08);
	}

	.nav-toggle:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
	}

	/* ---- The rail: wide screens, collapsed ----------------------------------------- */
	/* <html data-ovi-nav="collapsed"> is set before the first paint ($lib/nav-rail). The
	   query is the exact complement of the drawer's (max-width: 960px), so no width gets
	   both or neither. The rail keeps every name in the accessibility tree: link labels and
	   the account name are clipped out of sight, never display: none. */
	@media not all and (max-width: 960px) {
		/* overflow: visible lets the link tooltips extend over the chat; z-index keeps them
		   above it. */
		:global(html[data-ovi-nav='collapsed']) .shell-nav {
			z-index: 2;
			width: 72px;
			overflow: visible;
		}

		:global(html[data-ovi-nav='collapsed']) .brand {
			margin: 0 16px;
			justify-content: center;
		}

		:global(html[data-ovi-nav='collapsed']) .brand-text,
		:global(html[data-ovi-nav='collapsed']) .me-text,
		:global(html[data-ovi-nav='collapsed']) span.toggle-when-rail {
			position: absolute;
			width: 1px;
			height: 1px;
			margin: -1px;
			padding: 0;
			overflow: hidden;
			clip-path: inset(50%);
			white-space: nowrap;
		}

		/* The toggle's name in the rail (its "Collapse" text is hidden there). */
		:global(html[data-ovi-nav='collapsed']) span.toggle-when-rail {
			display: block;
		}

		:global(html[data-ovi-nav='collapsed']) .nav-links {
			align-items: center;
			gap: 6px;
			padding: 14px 0 6px;
		}

		:global(html[data-ovi-nav='collapsed']) .nav-links a {
			position: relative;
			box-sizing: border-box;
			width: 44px;
			height: 44px;
			padding: 0;
			border-radius: 12px;
			display: flex;
			align-items: center;
			justify-content: center;
			color: var(--ovi-text-strong);
		}

		:global(html[data-ovi-nav='collapsed']) .nav-links a:hover {
			background: var(--ovi-card);
			color: var(--ovi-text-primary);
			text-decoration: none;
			box-shadow: 0 1px 2px rgba(22, 22, 22, 0.08);
		}

		:global(html[data-ovi-nav='collapsed']) .nav-links a[aria-current='page'] {
			background: rgba(15, 98, 254, 0.1);
			color: var(--ovi-brand-primary);
			box-shadow: none;
		}

		:global(html[data-ovi-nav='collapsed']) .nav-icon {
			display: block;
			flex-shrink: 0;
		}

		/* The label is the tooltip: clipped to nothing (still the link's name) until the
		   link is hovered or focused. */
		:global(html[data-ovi-nav='collapsed']) .nav-label {
			position: absolute;
			top: 50%;
			left: calc(100% + 12px);
			z-index: 1;
			transform: translateY(-50%);
			padding: 6px 10px;
			border-radius: 6px;
			background: var(--ovi-text-primary);
			box-shadow: 0 2px 8px rgba(22, 22, 22, 0.2);
			color: #ffffff;
			font: 500 13px var(--ovi-font-sans);
			white-space: nowrap;
			clip-path: inset(50%);
		}

		/* The arrow pointing at the icon. */
		:global(html[data-ovi-nav='collapsed']) .nav-label::before {
			content: '';
			position: absolute;
			top: 50%;
			left: -4px;
			width: 8px;
			height: 8px;
			background: var(--ovi-text-primary);
			transform: translateY(-50%) rotate(45deg);
		}

		/* Bridges the gap to the icon, so the pointer can move onto the tooltip without it
		   disappearing (WCAG 1.4.13). */
		:global(html[data-ovi-nav='collapsed']) .nav-label::after {
			content: '';
			position: absolute;
			top: 0;
			right: 100%;
			bottom: 0;
			width: 12px;
		}

		:global(html[data-ovi-nav='collapsed']) .nav-links a:hover .nav-label,
		:global(html[data-ovi-nav='collapsed']) .nav-links a:focus-visible .nav-label {
			clip-path: none;
		}

		/* Escape hides it until the pointer leaves or focus moves. */
		:global(html[data-ovi-nav='collapsed']) .shell-nav.tips-dismissed .nav-links a .nav-label {
			clip-path: inset(50%);
		}

		:global(html[data-ovi-nav='collapsed']) .nav-me {
			align-items: center;
			padding: 18px 0 22px;
		}

		:global(html[data-ovi-nav='collapsed']) .me-note,
		:global(html[data-ovi-nav='collapsed']) .me-action,
		:global(html[data-ovi-nav='collapsed']) .toggle-when-full {
			display: none;
		}

		:global(html[data-ovi-nav='collapsed']) .nav-foot {
			display: flex;
			justify-content: center;
			padding: 8px 0;
		}

		:global(html[data-ovi-nav='collapsed']) .nav-toggle {
			width: 44px;
			padding: 0;
			justify-content: center;
		}

		:global(html[data-ovi-nav='collapsed']) path.toggle-when-rail {
			display: inline;
		}
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

		/* The drawer has no rail: the collapse control is for wide screens only. */
		.nav-foot {
			display: none;
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
