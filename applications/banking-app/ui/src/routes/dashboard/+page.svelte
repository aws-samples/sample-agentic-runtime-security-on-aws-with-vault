<!--
  Dashboard — Personalized banking view for authenticated users.

  Shows:
    - Account balances (fetched via agent → MCP → Vault → RDS with RLS)
    - Transaction history (same security path)
    - AI chat interface for natural-language banking queries

  The user's access_token is passed from the server-side layout data
  and forwarded to the agent pod via Authorization: Bearer header.
  The agent never stores tokens — each request is independently authenticated.

  Test users: Oscar and Adriana
-->
<script lang="ts">
	import type { PageData } from './$types';
	import { sendChatMessage } from '$lib/agent-client';

	let { data }: { data: PageData } = $props();

	// Chat state
	let messages: Array<{ role: string; content: string; type?: string }> = $state([]);
	let inputMessage = $state('');
	let isLoading = $state(false);
	let sessionId = $state(`session-${Date.now()}`);

	// Decode user identity from id_token for display
	let displayName = $state('');
	$effect(() => {
		if (data.idToken) {
			try {
				const parts = data.idToken.split('.');
				if (parts.length === 3) {
					const payload = JSON.parse(atob(parts[1]));
					const raw = payload.name ?? payload.preferred_username ?? payload.sub ?? 'User';
					displayName = raw.charAt(0).toUpperCase() + raw.slice(1);
				}
			} catch {
				displayName = 'User';
			}
		}
	});

	let chatEndpoint = $state('/api/chat');

	async function sendMessage() {
		if (!inputMessage.trim() || isLoading) return;

		const userMsg = inputMessage.trim();
		const endpoint = chatEndpoint;
		inputMessage = '';

		messages = [...messages, { role: 'user', content: userMsg }];
		isLoading = true;

		await sendChatMessage(
			userMsg,
			data.accessToken ?? '',
			sessionId,
			(chunk) => {
				if (chunk.type === 'end') {
					isLoading = false;
					return;
				}
				if (chunk.type === 'error') {
					messages = [...messages, { role: 'error', content: chunk.content }];
					isLoading = false;
					return;
				}
				if (chunk.content) {
					messages = [...messages, { role: chunk.role ?? 'ai', content: chunk.content, type: chunk.type }];
				}
			},
			(err) => {
				messages = [...messages, { role: 'error', content: `Error: ${err}` }];
				isLoading = false;
			},
			endpoint
		);
	}

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			sendMessage();
		}
	}
</script>

<div class="container">
	<!-- Welcome header -->
	<div class="dashboard-header">
		<div>
			<h1>Welcome{displayName ? `, ${displayName}` : ''}</h1>
			<p class="subtitle">
				Your banking data is personalized — Vault JWT auth + PostgreSQL RLS ensures you only see
				your own accounts and transactions.
			</p>
		</div>
		<div class="security-badges">
			<span class="badge badge-green">Identity-Bound Session</span>
			<span class="badge badge-blue">RLS Active</span>
		</div>
	</div>

	<!-- Chat interface -->
	<div class="card chat-card">
		<div class="chat-header">
			<h2>Banking Agent</h2>
			<span class="badge badge-aws">Powered by Amazon Nova Pro</span>
		</div>

		<div class="messages-container">
			{#if messages.length === 0}
				<div class="empty-state">
					<p>Ask me about your accounts or transactions:</p>
					<div class="suggestions">
						<button
							class="suggestion-btn"
							onclick={() => { inputMessage = 'Show me my account balances'; }}
						>
							Show my account balances
						</button>
						<button
							class="suggestion-btn"
							onclick={() => { inputMessage = 'What are my recent transactions?'; }}
						>
							Recent transactions
						</button>
						<button
							class="suggestion-btn"
							onclick={() => { inputMessage = 'Show transactions for my checking account'; }}
						>
							Checking account transactions
						</button>
						<button
							class="suggestion-btn suggestion-btn-refund"
							onclick={() => { inputMessage = 'I need a refund for a recent transaction'; chatEndpoint = '/api/uc3-chat'; }}
						>
							I need a refund
						</button>
					</div>
				</div>
			{:else}
				{#each messages as msg}
					<div class="message message-{msg.role} {msg.type === 'tool_planning' ? 'tool-planning' : ''}">
						{#if msg.role === 'user'}
							<span class="msg-label">You</span>
						{:else if msg.role === 'ai'}
							<span class="msg-label">Agent</span>
						{:else if msg.role === 'tool'}
							<span class="msg-label tool-label">Tool</span>
						{:else if msg.role === 'error'}
							<span class="msg-label error-label">Error</span>
						{/if}
						<div class="msg-content">{msg.content}</div>
					</div>
				{/each}

				{#if isLoading}
					<div class="message message-ai">
						<span class="msg-label">Agent</span>
						<div class="msg-content loading">Thinking...</div>
					</div>
				{/if}
			{/if}
		</div>

		<div class="chat-input-area">
			<textarea
				bind:value={inputMessage}
				onkeydown={handleKeydown}
				placeholder="Ask about your accounts or transactions..."
				rows="2"
				disabled={isLoading}
			></textarea>
			<button class="btn btn-primary send-btn" onclick={sendMessage} disabled={isLoading || !inputMessage.trim()}>
				Send
			</button>
		</div>
	</div>
</div>

<style>
	.dashboard-header {
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
	}

	.subtitle {
		font-size: 0.875rem;
		color: var(--color-text-secondary);
		margin: 0;
		max-width: 600px;
	}

	.security-badges {
		display: flex;
		gap: 0.5rem;
		flex-shrink: 0;
		flex-wrap: wrap;
	}

	.chat-card {
		display: flex;
		flex-direction: column;
		height: calc(100vh - 16rem);
		min-height: 500px;
	}

	.chat-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		margin-bottom: 1rem;
		padding-bottom: 0.75rem;
		border-bottom: 1px solid var(--color-border);
	}

	.chat-header h2 {
		margin: 0;
		font-size: 1.1rem;
		font-weight: 600;
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
		color: var(--color-text-secondary);
	}

	.suggestions {
		display: flex;
		gap: 0.5rem;
		justify-content: center;
		flex-wrap: wrap;
		margin-top: 1rem;
	}

	.suggestion-btn {
		background: var(--color-surface);
		border: 1px solid var(--color-border);
		border-radius: 0;
		padding: 0.5rem 0.75rem;
		font-size: 0.8rem;
		cursor: pointer;
		color: #0f62fe;
		font-family: inherit;
	}

	.suggestion-btn:hover {
		background: #d0e2ff;
		border-color: #0f62fe;
	}

	.suggestion-btn-refund {
		color: #da1e28;
		border-color: #da1e28;
	}

	.suggestion-btn-refund:hover {
		background: #ffd7d9;
		border-color: #da1e28;
	}

	.message {
		padding: 0.6rem 0.75rem;
		border-radius: 8px;
		max-width: 85%;
	}

	.message-user {
		background: #0f62fe;
		color: #fff;
		align-self: flex-end;
	}

	.message-ai {
		background: #e0e0e0;
		color: #161616;
		align-self: flex-start;
	}

	.message-tool,
	.tool-planning {
		background: #d0e2ff;
		font-size: 0.8rem;
		align-self: flex-start;
		opacity: 0.85;
	}

	.message-error {
		background: #ffd7d9;
		color: #750e13;
		align-self: flex-start;
	}

	.msg-label {
		display: block;
		font-size: 0.7rem;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		margin-bottom: 0.2rem;
		opacity: 0.7;
	}

	.tool-label {
		color: #92400e;
	}

	.error-label {
		color: var(--color-danger);
	}

	.msg-content {
		font-size: 0.9rem;
		line-height: 1.5;
		white-space: pre-wrap;
	}

	.chat-input-area {
		display: flex;
		gap: 0.75rem;
		align-items: flex-end;
		padding-top: 1rem;
		border-top: 1px solid var(--color-border);
		margin-top: 0.75rem;
	}

	textarea {
		flex: 1;
		padding: 0.6rem 0.75rem;
		border: 1px solid var(--color-border);
		border-radius: 6px;
		font-size: 0.9rem;
		font-family: inherit;
		resize: none;
		background: var(--color-bg);
	}

	textarea:focus {
		outline: none;
		border-color: var(--color-primary);
	}

	textarea:disabled {
		opacity: 0.6;
	}

	.send-btn {
		align-self: flex-end;
		padding: 0.6rem 1.2rem;
	}

	.send-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}
</style>
