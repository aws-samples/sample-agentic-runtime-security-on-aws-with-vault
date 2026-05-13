<!--
  Landing / Login page.

  Hosts the ROPC login form. Submitting username + password POSTs to the
  /login SvelteKit action (actions.default in login/+page.server.ts).

  The form action="/login" uses method="POST" so the submission goes to
  the SvelteKit action handler at src/routes/login/+page.server.ts, which
  calls passwordGrant() against IVIA, sets httpOnly cookies, and redirects
  to /dashboard.

  Error messages from failed login attempts arrive via the `error` query
  param (e.g. /?error=login_failed) and are surfaced below the form.
-->
<script lang="ts">
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	let username = $state('');
	let password = $state('');
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

		<form method="POST" action="/login" class="login-form">
			<div class="field">
				<label for="username">Username</label>
				<input
					id="username"
					type="text"
					name="username"
					required
					autocomplete="username"
					placeholder="e.g. oscar"
					bind:value={username}
				/>
			</div>
			<div class="field">
				<label for="password">Password</label>
				<input
					id="password"
					type="password"
					name="password"
					required
					autocomplete="current-password"
					placeholder="Password"
					bind:value={password}
				/>
			</div>
			<button type="submit" class="btn btn-primary login-btn">Sign in with IBM Verify</button>
		</form>

		{#if data.error}
			<p class="error-message">{data.error}</p>
		{/if}

		<div class="security-note">
			<span class="badge badge-blue">OAuth 2.0 ROPC</span>
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

	.login-form {
		display: flex;
		flex-direction: column;
		gap: 1rem;
		text-align: left;
		margin-bottom: 1rem;
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
	}

	.field label {
		font-size: 0.85rem;
		font-weight: 600;
		color: var(--color-text);
	}

	.field input {
		padding: 0.6rem 0.75rem;
		border: 1px solid var(--color-border, #d1d5db);
		border-radius: 6px;
		font-size: 0.95rem;
		color: var(--color-text);
		background: var(--color-surface, #fff);
		outline: none;
	}

	.field input:focus {
		border-color: var(--color-primary, #0f62fe);
		box-shadow: 0 0 0 2px rgba(15, 98, 254, 0.15);
	}

	.login-btn {
		width: 100%;
		justify-content: center;
		padding: 0.75rem;
		font-size: 1rem;
		margin-top: 0.5rem;
	}

	.error-message {
		color: #c53030;
		font-size: 0.875rem;
		margin: 0.5rem 0 1rem;
		padding: 0.5rem 0.75rem;
		background: #fff5f5;
		border: 1px solid #feb2b2;
		border-radius: 4px;
	}

	.security-note {
		display: flex;
		gap: 0.5rem;
		justify-content: center;
		flex-wrap: wrap;
		margin-top: 1rem;
	}
</style>
