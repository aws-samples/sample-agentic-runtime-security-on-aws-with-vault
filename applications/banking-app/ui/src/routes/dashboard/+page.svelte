<!--
  Dashboard — Personalized banking view for authenticated users.

  Shows:
    - Account balances (fetched via agent → MCP → Vault → RDS with RLS)
    - Transaction history (same security path)
    - AI chat interface for natural-language banking queries

  The user's access_token is passed from the server-side layout data
  and forwarded to the agent pod via Authorization: Bearer header.
  The agent never stores tokens — each request is independently authenticated.

  Test users: Oscar and Jaime
-->
<script lang="ts">
	import type { PageData } from './$types';
	import { sendChatMessage } from '$lib/agent-client';
	import { Tile, Tag, Button, TextArea, InlineNotification } from 'carbon-components-svelte';
	import Security from 'carbon-icons-svelte/lib/Security.svelte';
	import Locked from 'carbon-icons-svelte/lib/Locked.svelte';
	import ArrowRight from 'carbon-icons-svelte/lib/ArrowRight.svelte';

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
	let pendingConsent: { auth_req_id: string; request_id: string; user_code: string; details: string; consent_url: string } | null = $state(null);

	function extractConsent(text: string) {
		const match = text.match(/CIBA_CONSENT:auth_req_id=([^|]+)\|request_id=([^|]+)\|user_code=([^|]+)\|details=([^|]+)(?:\|consent_url=(\S+))?/);
		if (match) {
			pendingConsent = {
				auth_req_id: match[1],
				request_id: match[2],
				user_code: match[3],
				details: match[4].replace(/\*+$/, ''),
				consent_url: (match[5] ?? '').replace(/\*+$/, '')
			};
		}
	}

	// CIBA consent is granted on the OIDC provider's hosted consent page
	// (/isvaop/oauth2/ciba_user_authorize/{transactionID}, served via the WRP /isvaop
	// junction). The real URL is pushed by the IVIA notifyuser rule to the agent and
	// arrives in consent_url. The user opens it, signs in via the WRP session if
	// prompted, approves there, then tells the agent to finish — complete_refund polls
	// IVIA for the grant.
	function openConsent() {
		// Guard: only ever open an absolute http(s) URL. An empty/relative value would
		// resolve against the banking-ui origin and 404. consent_url is the WRP-hosted
		// /isvaop/oauth2/ciba_user_authorize/{txid} pushed by the IVIA notifyuser rule.
		if (!pendingConsent?.consent_url || !/^https?:\/\//.test(pendingConsent.consent_url)) return;
		window.open(pendingConsent.consent_url, '_blank', 'noopener');
		messages = [
			...messages,
			{
				role: 'ai',
				content: `On the IVIA consent page that just opened, approve the refund, then reply here (e.g. "I approved") so I can complete request ${pendingConsent.request_id}.`
			}
		];
		pendingConsent = null;
	}

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
					extractConsent(chunk.content);
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

<div class="page-narrow">
	<!-- Welcome header -->
	<div class="dashboard-header">
		<div>
			<h1>Welcome{displayName ? `, ${displayName}` : ''}</h1>
			<p class="subtitle">
				This dashboard demonstrates identity-bound data access — your token alone decides which
				accounts and transactions you can see, enforced in the data layer, not the UI.
			</p>
		</div>
		<div class="security-badges">
			<Tag type="green" icon={Security}>Identity-Bound Session</Tag>
			<Tag type="teal">RLS Active</Tag>
		</div>
	</div>

	<!-- Chat interface -->
	<Tile class="chat-card">
		<div class="chat-header">
			<h2>Banking Agent</h2>
			<Tag type="purple">Powered by Amazon Nova Pro</Tag>
		</div>

		<div class="messages-container">
			{#if messages.length === 0}
				<div class="empty-state">
					<p>Ask me about your accounts or transactions:</p>
					<div class="suggestions">
						<Button kind="tertiary" size="small" on:click={() => { inputMessage = 'Show me my account balances'; }}>
							Show my account balances
						</Button>
						<Button kind="tertiary" size="small" on:click={() => { inputMessage = 'What are my recent transactions?'; }}>
							Recent transactions
						</Button>
						<Button kind="tertiary" size="small" on:click={() => { inputMessage = 'Show transactions for my checking account'; }}>
							Checking account transactions
						</Button>
						<Button kind="danger-tertiary" size="small" on:click={() => { inputMessage = 'I need a refund for a recent transaction'; chatEndpoint = '/api/uc3-chat'; }}>
							I need a refund
						</Button>
					</div>
				</div>
			{:else}
				{#each messages as msg}
					{#if msg.role === 'tool'}
						<InlineNotification kind="info" lowContrast hideCloseButton title="Tool" subtitle={msg.content} />
					{:else if msg.role === 'error'}
						<InlineNotification kind="error" lowContrast hideCloseButton title="Error" subtitle={msg.content} />
					{:else}
						<div class="msg msg-{msg.role} {msg.type === 'tool_planning' ? 'msg-tool' : ''}">
							<span class="msg-label">{msg.role === 'user' ? 'You' : 'Agent'}</span>
							<div>{msg.content}</div>
						</div>
					{/if}
				{/each}

				{#if isLoading}
					<div class="msg msg-ai">
						<span class="msg-label">Agent</span>
						<div>Thinking…</div>
					</div>
				{/if}
			{/if}
		</div>

		{#if pendingConsent}
			<div class="consent">
				<div class="consent-head">
					<Locked size={20} />
					<strong>CIBA Consent Required (RFC 9126)</strong>
				</div>
				<p>The agent is requesting approval for a privileged action:</p>
				<p class="consent-details mono">{pendingConsent.details}</p>
				<p class="consent-rid">Request ID: <span class="mono">{pendingConsent.request_id}</span></p>
				<div class="consent-actions">
					<Button kind="primary" size="small" icon={ArrowRight} disabled={!pendingConsent.consent_url} on:click={openConsent}>
						Approve in IVIA
					</Button>
					<Button kind="danger-tertiary" size="small" on:click={() => { pendingConsent = null; messages = [...messages, { role: 'ai', content: 'Consent denied by user.' }]; }}>
						Deny
					</Button>
				</div>
			</div>
		{/if}

		<div class="chat-input-area">
			<TextArea
				bind:value={inputMessage}
				on:keydown={handleKeydown}
				labelText="Message to the banking agent"
				hideLabel
				placeholder="Ask about your accounts or transactions..."
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
	.dashboard-header {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		margin-bottom: 1.5rem;
		gap: 1rem;
		padding-top: 0.5rem;
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
		max-width: 600px;
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
		height: calc(100vh - 16rem);
		min-height: 500px;
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

	.suggestions {
		display: flex;
		gap: 0.5rem;
		justify-content: center;
		flex-wrap: wrap;
		margin-top: 1rem;
	}

	.consent {
		background: var(--cds-notification-background-warning, #fdf6dd);
		border-inline-start: 3px solid var(--cds-support-warning, #f1c21b);
		padding: 1rem;
		margin: 0.75rem 0;
	}

	.consent-head {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		margin-bottom: 0.5rem;
	}

	.consent p {
		margin: 0.25rem 0;
		font-size: 0.85rem;
		color: #161616;
	}

	.consent-details {
		background: #ffffff;
		border: 1px solid #e0e0e0;
		padding: 0.5rem;
		font-size: 0.8rem;
	}

	.consent-actions {
		display: flex;
		gap: 0.5rem;
		margin-top: 0.75rem;
	}

	.chat-input-area {
		display: flex;
		gap: 0.75rem;
		align-items: flex-end;
		padding-top: 1rem;
		border-top: 1px solid #e0e0e0;
		margin-top: 0.75rem;
	}

	.chat-input-area :global(.cds--form-item) {
		flex: 1;
	}
</style>
