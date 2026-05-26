<!--
  /ask — Public Use Case 1 demo page.

  Non-personalized, read-only agent. No sign-in: the uc1-agent authenticates
  itself to Vault with its Kubernetes workload identity and obtains JIT
  credentials to read the Bedrock Knowledge Base and Postgres. There is no
  end-user token here — that is the entire point of Use Case 1.

  The browser POSTs { query } to /api/ask, which proxies to uc1-agent-svc and
  returns { answer, sources, credential_metadata }.

  This page renders without the global OscarVault header (that only appears for
  authenticated sessions), so it carries its own lightweight banner.
-->
<script lang="ts">
	import { Tile, Tag, Button, TextArea, InlineNotification } from 'carbon-components-svelte';
	import Security from 'carbon-icons-svelte/lib/Security.svelte';
	import Bot from 'carbon-icons-svelte/lib/Bot.svelte';

	type Msg = { role: 'user' | 'ai' | 'error'; content: string };

	let messages: Msg[] = $state([]);
	let inputMessage = $state('');
	let isLoading = $state(false);

	// Auto-scroll the message list to the newest message. The effect re-runs
	// whenever a message is appended or the "Thinking…" indicator toggles.
	let messagesEl: HTMLDivElement | undefined = $state();
	$effect(() => {
		messages.length;
		isLoading;
		messagesEl?.scrollTo({ top: messagesEl.scrollHeight, behavior: 'smooth' });
	});

	const suggestions = [
		'Using the knowledge base, summarize the employee PTO policy.',
		'What is the remote work policy?',
		'How many vacation days do new employees get?'
	];

	function sendSuggestion(s: string) {
		if (isLoading) return;
		inputMessage = s;
		sendMessage();
	}

	async function sendMessage() {
		const query = inputMessage.trim();
		if (!query || isLoading) return;

		inputMessage = '';
		messages = [...messages, { role: 'user', content: query }];
		isLoading = true;

		try {
			const res = await fetch('/api/ask', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ query })
			});
			const data = await res.json();
			if (!res.ok) {
				messages = [...messages, { role: 'error', content: data?.error ?? `Request failed (${res.status})` }];
			} else {
				messages = [...messages, { role: 'ai', content: (data?.answer ?? '').trim() || '(empty answer)' }];
			}
		} catch (err) {
			messages = [...messages, { role: 'error', content: `Error: ${err instanceof Error ? err.message : String(err)}` }];
		} finally {
			isLoading = false;
		}
	}

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			sendMessage();
		}
	}
</script>

<div class="page-narrow">
	<!-- Self-contained banner (global header is hidden for unauthenticated visitors) -->
	<div class="ask-banner">
		<img src="/oscarvault-logo.svg" alt="OscarVault International (OVI)" class="ask-logo" />
		<a class="ask-signin bx--btn bx--btn--sm bx--btn--tertiary" href="/">Sign in</a>
	</div>

	<div class="ask-header">
		<div>
			<h1>Ask the Assistant</h1>
			<p class="subtitle">
				A public, read-only assistant that answers questions from OscarVault's internal knowledge
				base. No account or sign-in is required — the agent uses its own workload identity to fetch
				short-lived credentials, never your data.
			</p>
		</div>
		<div class="security-badges">
			<Tag type="green" icon={Security}>Workload Identity Only</Tag>
			<Tag type="teal">Read-Only</Tag>
		</div>
	</div>

	<Tile class="chat-card">
		<div class="chat-header">
			<h2>Use Case 1 — Non-Personalized Agent</h2>
			<Tag type="purple" icon={Bot}>Powered by Amazon Nova Pro</Tag>
		</div>

		<div class="messages-container" bind:this={messagesEl}>
			{#if messages.length === 0}
				<div class="empty-state">
					<p>Ask a question about company policies, or pick a starter prompt below.</p>
				</div>
			{:else}
				{#each messages as msg}
					{#if msg.role === 'error'}
						<InlineNotification kind="error" lowContrast hideCloseButton title="Error" subtitle={msg.content} />
					{:else}
						<div class="msg msg-{msg.role}">
							<span class="msg-label">{msg.role === 'user' ? 'You' : 'Assistant'}</span>
							<div>{msg.content}</div>
						</div>
					{/if}
				{/each}

				{#if isLoading}
					<div class="msg msg-ai">
						<span class="msg-label">Assistant</span>
						<div>Thinking…</div>
					</div>
				{/if}
			{/if}
		</div>

		<!-- Persistent starter prompts — always available, not just on the empty state -->
		<div class="suggestions-bar">
			{#each suggestions as s}
				<Button kind="tertiary" size="small" disabled={isLoading} on:click={() => sendSuggestion(s)}>
					{s}
				</Button>
			{/each}
		</div>

		<div class="chat-input-area">
			<TextArea
				bind:value={inputMessage}
				on:keydown={handleKeydown}
				labelText="Message to the assistant"
				hideLabel
				placeholder="Ask a question about company policies…"
				rows={2}
				disabled={isLoading}
			/>
			<Button kind="primary" on:click={sendMessage} disabled={isLoading || !inputMessage.trim()}>
				Send
			</Button>
		</div>
	</Tile>
</div>

<style>
	.ask-banner {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 0.75rem 0;
		margin-bottom: 1rem;
		border-bottom: 1px solid #e0e0e0;
	}

	.ask-logo {
		height: 2.5rem;
		width: auto;
		display: block;
	}

	.ask-signin {
		text-decoration: none;
	}

	.ask-header {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		margin-bottom: 1.5rem;
		gap: 1rem;
	}

	h1 {
		font-size: 1.6rem;
		font-weight: 700;
		margin: 0 0 0.25rem;
		color: #161616;
	}

	.subtitle {
		font-size: 0.875rem;
		color: #525252;
		margin: 0;
		max-width: 620px;
	}

	.security-badges {
		display: flex;
		gap: 0.5rem;
		flex-shrink: 0;
		flex-wrap: wrap;
	}

	:global(.chat-card) {
		display: flex;
		flex-direction: column;
		height: calc(100vh - 18rem);
		min-height: 460px;
	}

	.chat-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		margin-bottom: 1rem;
		padding-bottom: 0.75rem;
		border-bottom: 1px solid #e0e0e0;
	}

	.chat-header h2 {
		margin: 0;
		font-size: 1.1rem;
		font-weight: 600;
		color: #161616;
	}

	.messages-container {
		flex: 1;
		overflow-y: auto;
		padding: 0.5rem 0;
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.empty-state {
		padding: 2rem;
		text-align: center;
		color: #525252;
	}

	/* Message-bubble styling (.msg / .msg-user / .msg-ai / .msg-label) is
	   inherited from the global app.css so this page matches the signed-in
	   dashboard chat exactly. Do not redefine those here. */

	.suggestions-bar {
		display: flex;
		gap: 0.5rem;
		flex-wrap: wrap;
		padding-top: 0.75rem;
		margin-top: 0.5rem;
		border-top: 1px solid #e0e0e0;
	}

	.chat-input-area {
		display: flex;
		gap: 0.75rem;
		align-items: flex-end;
		padding-top: 0.75rem;
	}

	.chat-input-area :global(.cds--form-item) {
		flex: 1;
	}
</style>
