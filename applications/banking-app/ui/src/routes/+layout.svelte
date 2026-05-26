<script lang="ts">
	// Carbon Design System — g10 (light) theme as the token source of truth.
	// Imported before app.css so our brand overrides (blue header) win the cascade.
	import 'carbon-components-svelte/css/g10.css';
	import '../app.css';

	import {
		Header,
		HeaderNav,
		HeaderNavItem,
		HeaderUtilities,
		HeaderAction,
		Content
	} from 'carbon-components-svelte';
	import UserAvatarMenu from '$lib/UserAvatarMenu.svelte';
	import type { LayoutData } from './$types';

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	let userMenuOpen = $state(false);

	function logout() {
		window.location.href = '/logout';
	}
</script>

{#if data.accessToken}
	<Header href="/dashboard">
		<svelte:fragment slot="company">
			<img src="/oscarvault-logo-white.svg" alt="OscarVault International (OVI)" class="brand-logo" />
		</svelte:fragment>
		<span class="header-tagline">Agentic Runtime Security Workshop</span>
		<HeaderNav>
			<HeaderNavItem href="/dashboard" text="Dashboard" data-sveltekit-reload />
		</HeaderNav>
		<HeaderUtilities>
			<!--
				HeaderAction (carbon-components-svelte ^0.107.1):
				  - `icon` named slot renders the trigger button content (the round avatar photo)
				  - Default slot renders the dropdown panel (display name + logout)
				  - bind:isOpen two-way binds the open/close state
			-->
			<HeaderAction
				bind:isOpen={userMenuOpen}
				aria-label={data.displayName || 'User menu'}
				preventCloseOnClickOutside={false}
			>
				<svelte:fragment slot="icon">
					<UserAvatarMenu displayName={data.displayName} sub={data.sub} />
				</svelte:fragment>
				<svelte:fragment slot="closeIcon">
					<UserAvatarMenu displayName={data.displayName} sub={data.sub} />
				</svelte:fragment>

				<!-- Dropdown panel: display name + logout -->
				<div class="user-menu-panel">
					{#if data.displayName}
						<p class="user-menu-name">{data.displayName}</p>
					{/if}
					<button class="user-menu-logout bx--btn bx--btn--ghost" onclick={logout} type="button">
						Log out
					</button>
				</div>
			</HeaderAction>
		</HeaderUtilities>
	</Header>
{/if}

<Content>
	{@render children()}
</Content>

<style>
	.user-menu-panel {
		padding: 1rem;
		min-width: 200px;
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.user-menu-name {
		margin: 0;
		font-size: 0.875rem;
		font-weight: 600;
		color: var(--cds-text-01, #161616);
		word-break: break-all;
	}

	.user-menu-logout {
		align-self: flex-start;
		padding: 0.5rem 0;
	}

	/* OscarVault logo in the header brand link — sized to the 3rem nav bar. */
	.brand-logo {
		height: 2.25rem;
		width: auto;
		display: block;
	}
</style>
