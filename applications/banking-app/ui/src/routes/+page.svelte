<!--
  Landing / Login page.

  If user is already authenticated (has access_token cookie), redirects
  to dashboard. Otherwise, shows a login button that initiates the
  Authorization Code + PKCE flow to IVIA.

  The login redirect is done server-side via +page.server.ts to avoid
  exposing the IVIA issuer URL in client-side JavaScript.
-->
<script lang="ts">
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();
</script>

<div class="login-page">
	<div class="login-card card">
		<div class="login-logo">🏦</div>
		<h1>CDL Bank</h1>
		<p class="subtitle">Agentic Runtime Security Workshop — Use Case 2</p>
		<p class="description">
			Sign in with your IBM Verify Access identity to access your personalized banking dashboard.
			Your identity is cryptographically bound to every database query via OAuth + Vault JWT auth.
		</p>
		<a href="/login" class="btn btn-primary login-btn">Sign in with IBM Verify</a>
		<div class="security-note">
			<span class="badge badge-blue">OAuth 2.0 + PKCE</span>
			<span class="badge badge-green">Vault JWT Auth</span>
			<span class="badge badge-blue">PostgreSQL RLS</span>
		</div>
	</div>
</div>

<style>
	.login-page {
		min-height: calc(100vh - 4rem);
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 2rem;
	}

	.login-card {
		max-width: 420px;
		width: 100%;
		text-align: center;
	}

	.login-logo {
		font-size: 3rem;
		margin-bottom: 0.5rem;
	}

	h1 {
		font-size: 1.8rem;
		font-weight: 700;
		margin: 0 0 0.25rem;
		color: var(--color-text);
	}

	.subtitle {
		font-size: 0.8rem;
		color: var(--color-text-secondary);
		margin: 0 0 1.5rem;
	}

	.description {
		font-size: 0.9rem;
		color: var(--color-text-secondary);
		line-height: 1.6;
		margin-bottom: 1.5rem;
	}

	.login-btn {
		width: 100%;
		justify-content: center;
		padding: 0.75rem;
		font-size: 1rem;
		margin-bottom: 1.5rem;
	}

	.security-note {
		display: flex;
		gap: 0.5rem;
		justify-content: center;
		flex-wrap: wrap;
	}
</style>
