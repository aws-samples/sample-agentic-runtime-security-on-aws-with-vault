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
		HeaderGlobalAction,
		Content
	} from 'carbon-components-svelte';
	import Logout from 'carbon-icons-svelte/lib/Logout.svelte';
	import type { LayoutData } from './$types';

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	function logout() {
		window.location.href = '/logout';
	}
</script>

{#if data.accessToken}
	<Header companyName="OscarVault" platformName="International (OVI)" href="/dashboard">
		<span class="header-tagline">Agentic Runtime Security Workshop</span>
		<HeaderNav>
			<HeaderNavItem href="/dashboard" text="Dashboard" data-sveltekit-reload />
		</HeaderNav>
		<HeaderUtilities>
			<HeaderGlobalAction aria-label="Logout" title="Logout" icon={Logout} on:click={logout} />
		</HeaderUtilities>
	</Header>
{/if}

<Content>
	{@render children()}
</Content>
