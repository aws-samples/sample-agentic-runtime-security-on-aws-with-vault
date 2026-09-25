<!--
  PersonaMenu — the signed-in account at the foot of the left navigation, and the menu it opens.

  Clicking the photo and name opens a menu above them (the chevron flips): ID Token Claims,
  Access Token Claims, then Log out. A presenter uses it to show the room what the two tokens
  IBM Verify issued at sign-in actually say. One section is open at a time, ID Token Claims
  when the menu opens; each claims table scrolls inside the menu.

  The claims arrive already decoded from the layout (lib/server/sign-in-claims.ts); the page
  never holds the token strings for this. Values render as text, never as HTML.

  Props:
    displayName, role, avatar, initials  the account as the navigation shows it
    claims    the decoded id_token and access_token claims
    anchor    the navigation's account block; the menu opens 8px above its top edge and
              16px in from its left, and never runs above the navigation's own top
    open      bindable; the layout closes it with the drawer and routes Escape to close()
    onnavigate  called when Log out is followed, so the layout can close the drawer

  Closing: Escape (through close(), from the layout's one window key handler), the button, or
  a click anywhere outside. Focus returns to the button, except when the outside click landed
  on a control in the Tab order (the chat input, say), which keeps it. A click on plain page
  focuses <main> (tabindex="-1", the skip link's target); that is not a control, so focus
  still comes back to the button.

  In the collapsed navigation (the 72px icon rail) the button is the photo alone and the name
  stays its accessible name, clipped out of sight as the rail clips every label.
-->
<script lang="ts">
	import { claimRows, type SignInClaims, type TokenClaims } from '$lib/token-claims';

	type Section = 'id' | 'access';

	interface Props {
		displayName: string;
		role?: string;
		avatar?: string;
		initials: string;
		claims: SignInClaims;
		anchor: HTMLElement | undefined;
		open?: boolean;
		onnavigate?: () => void;
	}

	let { displayName, role, avatar, initials, claims, anchor, open = $bindable(false), onnavigate }: Props = $props();

	const uid = $props.id();
	const menuId = `${uid}-menu`;

	// As drawn: the menu's bottom edge 8px above the account block, its left edge 16px in.
	const GAP = 8;
	const INSET = 16;
	// The menu never runs closer than this to the top of the navigation (the window's top on
	// wide screens, the top bar's bottom edge in the drawer); past that it scrolls.
	const EDGE = 16;

	let section: Section | null = $state('id');
	let button: HTMLButtonElement | undefined = $state();
	let root: HTMLDivElement | undefined = $state();
	let place = $state({ bottom: 0, left: 0, maxHeight: 0 });

	function measure() {
		if (!anchor) return;
		const block = anchor.getBoundingClientRect();
		const navTop = Math.max(0, anchor.closest('nav')?.getBoundingClientRect().top ?? 0);
		place = {
			bottom: document.documentElement.clientHeight - block.top + GAP,
			left: block.left + INSET,
			maxHeight: Math.max(0, block.top - GAP - navTop - EDGE)
		};
	}

	function openMenu() {
		section = 'id';
		measure();
		open = true;
	}

	/** Closes the menu; focus goes back to the button unless told otherwise. */
	export function close({ returnFocus = true } = {}) {
		if (!open) return;
		open = false;
		if (returnFocus) button?.focus();
	}

	function toggle() {
		if (open) close();
		else openMenu();
	}

	function toggleSection(key: Section) {
		section = section === key ? null : key;
	}

	// While open: follow the window's size and any scrolling, and close on a click outside.
	// The click listener is on the capture phase, so a handler that stops propagation cannot
	// hide an outside click from it, and focus has already moved to whatever was clicked.
	$effect(() => {
		if (!open) return;
		const onViewport = () => measure();
		const onClick = (e: MouseEvent) => {
			if (root?.contains(e.target as Node)) return;
			const active = document.activeElement;
			const keptElsewhere =
				active instanceof HTMLElement && active !== document.body && !root?.contains(active) && active.tabIndex >= 0;
			close({ returnFocus: !keptElsewhere });
		};
		window.addEventListener('resize', onViewport);
		window.addEventListener('scroll', onViewport, true);
		document.addEventListener('click', onClick, true);
		return () => {
			window.removeEventListener('resize', onViewport);
			window.removeEventListener('scroll', onViewport, true);
			document.removeEventListener('click', onClick, true);
		};
	});

	function followLogout() {
		open = false;
		onnavigate?.();
	}
</script>

{#snippet chevron(up: boolean, cls: string)}
	<svg class={cls} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
		{#if up}
			<path d="M4 10l4-4 4 4"></path>
		{:else}
			<path d="M4 6l4 4 4-4"></path>
		{/if}
	</svg>
{/snippet}

{#snippet tokenSection(key: Section, title: string, token: TokenClaims, cookie: string)}
	{@const expanded = section === key}
	<div class="sec" class:open={expanded}>
		<button type="button" class="sec-head" aria-expanded={expanded} aria-controls="{uid}-{key}" onclick={() => toggleSection(key)}>
			{#if key === 'id'}
				<svg class="sec-icon" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
					<rect x="2.5" y="4.5" width="15" height="11" rx="2"></rect>
					<circle cx="7.5" cy="9.5" r="2"></circle>
					<path d="M4.8 13.5c.6-1.3 1.6-2 2.7-2s2.1.7 2.7 2M12 8.5h3M12 11.5h3"></path>
				</svg>
			{:else}
				<svg class="sec-icon" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
					<circle cx="6.5" cy="10" r="3.5"></circle>
					<path d="M10 10h7.5M15 10v3M17.5 10v2"></path>
				</svg>
			{/if}
			{title}
			{@render chevron(expanded, 'sec-chev')}
		</button>
		<div id="{uid}-{key}" hidden={!expanded}>
			{#if token.readable}
				<p class="sec-sub">Decoded from the {cookie} cookie IBM Verify issued at sign-in</p>
				<!-- The table scrolls inside the menu, so it takes focus to scroll from the keyboard. -->
				<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
				<div class="claims" role="region" aria-label={title} tabindex="0">
					<table>
						<tbody>
							{#each claimRows(token.claims) as row (row.name)}
								<tr>
									<th scope="row">{row.name}</th>
									<td>{row.value}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{:else}
				<p class="sec-sub sec-unreadable">The claims in the {cookie} cookie could not be read.</p>
			{/if}
		</div>
	</div>
{/snippet}

<div class="persona" bind:this={root}>
	<button
		bind:this={button}
		type="button"
		class="me-button"
		aria-haspopup="dialog"
		aria-expanded={open}
		aria-controls={open ? menuId : undefined}
		onclick={toggle}
	>
		<!-- The name is printed beside the photo, so the photo itself is decorative. -->
		{#if avatar}
			<img class="me-avatar avatar-photo" src={avatar} alt="" />
		{:else}
			<span class="me-avatar" aria-hidden="true">{initials}</span>
		{/if}
		<span class="me-text">
			<span class="me-name">{displayName}</span>
			{#if role}
				<span class="me-role">{role}</span>
			{/if}
		</span>
		{@render chevron(open, 'me-chev')}
	</button>

	{#if open}
		<div
			id={menuId}
			class="menu"
			role="dialog"
			aria-label={displayName}
			tabindex="-1"
			style:bottom="{place.bottom}px"
			style:left="{place.left}px"
			style:max-height="{place.maxHeight}px"
		>
			{@render tokenSection('id', 'ID Token Claims', claims.idToken, 'id_token')}
			{@render tokenSection('access', 'Access Token Claims', claims.accessToken, 'access_token')}
			<!-- GET /logout clears the session cookies and ends the IVIA WebSEAL session.
			     data-sveltekit-reload makes this a full navigation that SvelteKit never
			     preloads, so hovering the link cannot sign anyone out. -->
			<a class="logout" href="/logout" data-sveltekit-reload onclick={followLogout}>
				<svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
					<path d="M8 4H5a1.5 1.5 0 0 0-1.5 1.5v9A1.5 1.5 0 0 0 5 16h3M12.5 13.5L16 10l-3.5-3.5M16 10H8"></path>
				</svg>
				Log out
			</a>
		</div>
	{/if}
</div>

<style>
	/* ---- The account button ------------------------------------------------------- */
	.me-button {
		box-sizing: border-box;
		width: 100%;
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 8px;
		border: 0;
		border-radius: 12px;
		background: var(--ovi-card);
		box-shadow: 0 0 0 1px var(--ovi-hairline-strong);
		color: var(--ovi-text-primary);
		font: inherit;
		letter-spacing: inherit;
		text-align: left;
		cursor: pointer;
	}

	.me-button:hover {
		box-shadow:
			0 0 0 1px var(--ovi-border),
			0 1px 2px rgba(22, 22, 22, 0.08);
	}

	.me-button:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
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

	/* A persona's photo: the avatar circle's size and shape, cropped to fill it. */
	.avatar-photo {
		object-fit: cover;
	}

	.me-text {
		min-width: 0;
		display: flex;
		flex-direction: column;
	}

	/* On the white button the board's own colours meet 4.5:1 (amber 4.99:1, grey 4.54:1),
	   unlike on the navigation's blue, where the navigation uses darker ones. */
	.me-name {
		font-weight: 600;
		font-size: 16px;
		color: var(--ovi-amber);
		overflow-wrap: anywhere;
	}

	.me-role {
		font-size: 13px;
		color: var(--ovi-text-helper);
	}

	.me-chev {
		flex-shrink: 0;
		margin-left: auto;
		color: var(--ovi-text-helper);
	}

	/* ---- The menu ----------------------------------------------------------------- */
	/* Fixed, because the navigation scrolls (overflow-y: auto) and is narrower than the menu:
	   inside it, the menu would be clipped. The layout lifts the navigation above the page
	   while the menu is open. */
	.menu {
		position: fixed;
		box-sizing: border-box;
		width: min(372px, calc(100vw - 32px));
		overflow-y: auto;
		padding: 8px 0;
		border-radius: 14px;
		background: var(--ovi-card);
		box-shadow:
			0 0 0 1px var(--ovi-hairline-strong),
			0 16px 40px rgba(22, 22, 22, 0.18);
		color: var(--ovi-text-primary);
		text-align: left;
	}

	.menu:focus {
		outline: none;
	}

	.sec {
		border-top: 1px solid var(--ovi-hairline-strong);
	}

	.sec:first-child {
		border-top: 0;
	}

	.sec-head {
		box-sizing: border-box;
		width: 100%;
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 12px 18px;
		border: 0;
		background: none;
		color: var(--ovi-text-primary);
		font: 500 15px var(--ovi-font-sans);
		letter-spacing: normal;
		text-align: left;
		cursor: pointer;
	}

	.sec.open .sec-head,
	.sec-head:hover {
		background: var(--ovi-surface-bg);
	}

	.sec-head:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: -2px;
	}

	.sec-icon {
		width: 18px;
		height: 18px;
		flex-shrink: 0;
		color: var(--ovi-brand-primary);
	}

	.sec-chev {
		flex-shrink: 0;
		margin-left: auto;
		color: var(--ovi-text-helper);
	}

	/* line-height: normal, as drawn; Carbon sets 1.5 on every <p>. */
	.sec-sub {
		margin: 0;
		padding: 0 18px 6px;
		font-size: 12.5px;
		line-height: normal;
		color: var(--ovi-text-helper);
	}

	.sec-unreadable {
		padding-top: 8px;
		padding-bottom: 12px;
	}

	/* content-box, as drawn: the 318px and the key column's 104px are content sizes there, and
	   Carbon makes every box border-box. */
	.claims {
		box-sizing: content-box;
		max-height: 318px;
		overflow: auto;
		margin: 4px 18px 10px;
		border: 1px solid var(--ovi-hairline-strong);
		border-radius: 10px;
	}

	.claims:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: 2px;
	}

	.claims table {
		width: 100%;
		border-collapse: collapse;
		font: 12.5px/1.45 var(--ovi-font-mono);
		letter-spacing: normal;
	}

	.claims th,
	.claims td {
		box-sizing: content-box;
		padding: 7px 10px;
		vertical-align: top;
		border-top: 1px solid var(--ovi-hairline);
	}

	.claims tr:first-child th,
	.claims tr:first-child td {
		border-top: 0;
	}

	.claims th {
		width: 104px;
		color: var(--ovi-text-helper);
		font-weight: 400;
		text-align: left;
		white-space: nowrap;
	}

	.claims td {
		color: var(--ovi-text-primary);
		word-break: break-all;
	}

	/* Carbon Red 60, as drawn: 4.99:1 on white. */
	.logout {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 12px 18px;
		border-top: 1px solid var(--ovi-hairline-strong);
		color: #da1e28;
		font: 500 15px var(--ovi-font-sans);
		letter-spacing: normal;
		text-decoration: none;
	}

	.logout:hover {
		background: var(--ovi-surface-bg);
	}

	.logout:focus-visible {
		outline: var(--ovi-focus-ring);
		outline-offset: -2px;
	}

	/* ---- The rail: wide screens, collapsed ($lib/nav-rail) --------------------------- */
	/* The button is the photo alone. The name stays its accessible name, clipped out of
	   sight the way the rail clips every label. */
	@media not all and (max-width: 960px) {
		:global(html[data-ovi-nav='collapsed']) .me-button {
			width: auto;
			padding: 0;
			border-radius: 50%;
			background: none;
			box-shadow: none;
		}

		:global(html[data-ovi-nav='collapsed']) .me-text {
			position: absolute;
			width: 1px;
			height: 1px;
			margin: -1px;
			padding: 0;
			overflow: hidden;
			clip-path: inset(50%);
			white-space: nowrap;
		}

		:global(html[data-ovi-nav='collapsed']) .me-chev {
			display: none;
		}
	}
</style>
