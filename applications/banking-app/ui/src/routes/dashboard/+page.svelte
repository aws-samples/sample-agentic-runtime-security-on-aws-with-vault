<!--
  Dashboard — Personalized banking chat for authenticated users (Use Case 2).

  The chat answers questions about the member's accounts and transactions
  (fetched via agent → MCP → Vault → RDS with RLS). The refund suggestion switches
  the chat to the Use Case 3 agent (/api/uc3-chat).

  The server-side proxy at /api/chat (and /api/uc3-chat) reads the user's
  access_token from its httpOnly cookie and forwards it to the agent pod as
  Authorization: Bearer. The agent never stores tokens — each request is
  independently authenticated.

  Every agent event of each turn is kept per turn ($lib/turn-events.svelte) and
  printed by the Agent Log; the chat bubbles still come from the legacy frames
  only, so an agent event never becomes a bubble.

  Test users: Oscar and Jaime
-->
<script lang="ts">
	import type { PageData } from './$types';
	import { sendChatMessage } from '$lib/agent-client';
	import { getPersona } from '$lib/personas';
	import { Button, InlineNotification } from 'carbon-components-svelte';
	import Locked from 'carbon-icons-svelte/lib/Locked.svelte';
	import ArrowRight from 'carbon-icons-svelte/lib/ArrowRight.svelte';
	import ChatWorkspace, { type Suggestion } from '$lib/components/chat/ChatWorkspace.svelte';
	import UserMessage from '$lib/components/chat/UserMessage.svelte';
	import AgentTurn from '$lib/components/chat/AgentTurn.svelte';
	import ToolChip from '$lib/components/chat/ToolChip.svelte';
	import AnswerCard from '$lib/components/chat/AnswerCard.svelte';
	import AgentLogPanel from '$lib/components/activity/AgentLogPanel.svelte';
	import { countEntries } from '$lib/agent-log';
	import { createTurnLog } from '$lib/turn-events.svelte';

	let { data }: { data: PageData } = $props();

	/** The agent that answers on an endpoint: the refund chat (Use Case 3) or the banking chat. */
	type AgentName = 'Banking Agent' | 'Refund Agent';
	const agentFor = (endpoint: string): AgentName => (endpoint === '/api/uc3-chat' ? 'Refund Agent' : 'Banking Agent');

	/** `agent` is set on every agent-side message: the agent whose turn it belongs to. */
	type Msg = { role: string; content: string; type?: string; agent?: AgentName };
	type Turn = { kind: 'user'; msg: Msg } | { kind: 'agent'; agent: AgentName; msgs: Msg[] };

	// Chat state
	let messages: Msg[] = $state([]);
	let inputMessage = $state('');
	let isLoading = $state(false);
	let sessionId = $state(`session-${Date.now()}`);

	let chatEndpoint = $state('/api/chat');

	// Every agent event of each turn, for the Agent Log.
	const log = createTurnLog();
	/** Which right-hand panel is open. Shared convention with the other chat pages. */
	let openPanel = $state<'log' | 'flow' | null>(null);
	const entryCount = $derived(countEntries(log.turns));
	// The systems the current chat uses: the refund chat (Use Case 3) writes to Postgres
	// itself; the banking chat (Use Case 2) reaches it through the MCP server.
	const systems = $derived(chatEndpoint === '/api/uc3-chat' ? 'IVIA · Vault · Postgres' : 'IVIA · Vault · MCP');
	// The chat header names the agent answering: the refund chat's is the Refund Agent.
	const title = $derived(agentFor(chatEndpoint));
	const inputLabel = $derived(chatEndpoint === '/api/uc3-chat' ? 'Message the refund agent' : 'Message the banking agent');

	function toggleLog() {
		openPanel = openPanel === 'log' ? null : 'log';
	}
	/** `agent` is the agent whose turn asked for the consent. */
	let pendingConsent: {
		auth_req_id: string;
		request_id: string;
		user_code: string;
		details: string;
		consent_url: string;
		agent: AgentName;
	} | null = $state(null);

	// Auto-scroll the message list to the newest message. The effect re-runs
	// whenever a message is appended, the "Thinking…" indicator toggles, or the
	// consent card appears.
	let messagesEl: HTMLDivElement | undefined = $state();
	$effect(() => {
		messages.length;
		isLoading;
		pendingConsent;
		messagesEl?.scrollTo({ top: messagesEl.scrollHeight, behavior: 'smooth' });
	});

	// Display only: the persona name from the layout's id_token decode.
	let actingFor = $derived(getPersona(data.sub)?.fullName ?? data.displayName);
	// The refund chat's approvals go to the member's phone through IBM Verify.
	let subtitle = $derived(
		(chatEndpoint === '/api/uc3-chat'
			? [actingFor ? `Acting for ${actingFor}` : '', 'approvals by IBM Verify']
			: [actingFor ? `Acting for ${actingFor}` : '', 'Amazon Nova Pro', 'Vault-secured']
		)
			.filter(Boolean)
			.join(' · ')
	);

	// Consecutive agent-side messages (tool steps, answer, errors) of the same agent render as
	// one agent turn, named for that agent: a banking turn stays "Banking Agent" after the chat
	// moves to the refund agent.
	let turns = $derived.by(() => {
		const out: Turn[] = [];
		for (const msg of messages) {
			const last = out.at(-1);
			const agent = msg.agent ?? 'Banking Agent';
			if (msg.role === 'user') out.push({ kind: 'user', msg });
			else if (last?.kind === 'agent' && last.agent === agent) last.msgs.push(msg);
			else out.push({ kind: 'agent', agent, msgs: [msg] });
		}
		return out;
	});

	function extractConsent(text: string, agent: AgentName) {
		const match = text.match(/CIBA_CONSENT:auth_req_id=([^|]+)\|request_id=([^|]+)\|user_code=([^|]+)\|details=([^|]+)(?:\|consent_url=(\S+))?/);
		if (match) {
			pendingConsent = {
				auth_req_id: match[1],
				request_id: match[2],
				user_code: match[3],
				details: match[4].replace(/\*+$/, ''),
				consent_url: (match[5] ?? '').replace(/\*+$/, ''),
				agent
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
				content: `On the IVIA consent page that just opened, approve the refund, then reply here (e.g. "I approved") so I can complete request ${pendingConsent.request_id}.`,
				agent: pendingConsent.agent
			}
		];
		pendingConsent = null;
	}

	function denyConsent() {
		const agent = pendingConsent?.agent;
		pendingConsent = null;
		messages = [...messages, { role: 'ai', content: 'Consent denied by user.', agent }];
	}

	// Persistent starter prompts. The refund prompt also switches the chat to the
	// UC3 CIBA endpoint before sending (mirrors the old empty-state behavior).
	function sendSuggestion(text: string, endpoint = '/api/chat') {
		if (isLoading) return;
		chatEndpoint = endpoint;
		inputMessage = text;
		sendMessage();
	}

	const suggestions: Suggestion[] = [
		{ label: 'Show me my account balances', onselect: () => sendSuggestion('Show me my account balances') },
		{ label: 'What are my recent transactions?', onselect: () => sendSuggestion('What are my recent transactions?') },
		{
			label: 'Show transactions for my checking account',
			onselect: () => sendSuggestion('Show transactions for my checking account')
		},
		{
			label: 'I need a refund for a recent transaction',
			tone: 'warn',
			onselect: () => sendSuggestion('I need a refund for a recent transaction', '/api/uc3-chat')
		}
	];

	async function sendMessage() {
		if (!inputMessage.trim() || isLoading) return;

		const userMsg = inputMessage.trim();
		const endpoint = chatEndpoint;
		const agent = agentFor(endpoint);
		inputMessage = '';

		messages = [...messages, { role: 'user', content: userMsg }];
		isLoading = true;
		const turn = log.begin(userMsg);

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
					messages = [...messages, { role: 'error', content: chunk.content, agent }];
					isLoading = false;
					return;
				}
				if (chunk.content) {
					extractConsent(chunk.content, agent);
					messages = [...messages, { role: chunk.role ?? 'ai', content: chunk.content, type: chunk.type, agent }];
				}
			},
			(err) => {
				messages = [...messages, { role: 'error', content: `Error: ${err}`, agent }];
				isLoading = false;
			},
			endpoint,
			(event) => log.push(event, turn)
		);
		log.end(turn);
	}
</script>

<svelte:head>
	<title>{title} — OscarVault International</title>
</svelte:head>

{#snippet agentIcon()}
	<svg width="16" height="16" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
		<rect x="3" y="4" width="14" height="10" rx="2"></rect>
		<path d="M7 17h6"></path>
	</svg>
{/snippet}

<ChatWorkspace
	{title}
	{subtitle}
	statusLabel="Identity-bound"
	agentLogOpen={openPanel === 'log'}
	agentLogCount={entryCount}
	agentLogControls="agent-log"
	onAgentLogToggle={toggleLog}
	securityFlowOpen={openPanel === 'flow'}
	bind:messagesEl
	{suggestions}
	bind:value={inputMessage}
	busy={isLoading}
	inputId="dashboard-message"
	{inputLabel}
	placeholder="Ask about your accounts, transactions or a refund…"
	onsend={sendMessage}
	hint="Enter to send · Shift+Enter for new line · The refund agent keeps this conversation for the session"
>
	{#snippet icon()}
		<svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
			<rect x="3" y="4" width="14" height="10" rx="2"></rect>
			<path d="M7 17h6M10 14v3"></path>
		</svg>
	{/snippet}

	{#snippet panel()}
		{#if openPanel === 'log'}
			<AgentLogPanel id="agent-log" turns={log.turns} {systems} onclose={() => (openPanel = null)} />
		{/if}
	{/snippet}

	{#if messages.length === 0}
		<p class="empty-state">Ask me about your accounts or transactions, or pick a starter prompt below.</p>
	{/if}

	{#each turns as turn, i}
		{#if turn.kind === 'user'}
			<UserMessage>{turn.msg.content}</UserMessage>
		{:else}
			<AgentTurn label={turn.agent} icon={agentIcon}>
				{#each turn.msgs as msg}
					{#if msg.role === 'tool' || msg.type === 'tool_planning'}
						<ToolChip label={msg.content} />
					{:else if msg.role === 'error'}
						<InlineNotification kind="error" lowContrast hideCloseButton title="Error" subtitle={msg.content} />
					{:else}
						<AnswerCard>{msg.content}</AnswerCard>
					{/if}
				{/each}
				{#if isLoading && i === turns.length - 1}
					<AnswerCard pending>Thinking…</AnswerCard>
				{/if}
			</AgentTurn>
		{/if}
	{/each}

	{#if isLoading && turns.at(-1)?.kind !== 'agent'}
		<AgentTurn label={agentFor(chatEndpoint)} icon={agentIcon}>
			<AnswerCard pending>Thinking…</AnswerCard>
		</AgentTurn>
	{/if}

	{#if pendingConsent}
		<AgentTurn label={pendingConsent.agent} icon={agentIcon}>
			<div class="approval" role="group" aria-labelledby="consent-title">
				<span class="approval-icon" aria-hidden="true"><Locked size={16} /></span>
				<div class="approval-body">
					<p id="consent-title" class="approval-title">CIBA Consent Required (OpenID Connect CIBA)</p>
					<p>The agent is requesting approval for a privileged action:</p>
					<p class="approval-details mono">{pendingConsent.details}</p>
					<p class="approval-meta">Request ID: <span class="mono">{pendingConsent.request_id}</span></p>
					<div class="approval-actions">
						<Button kind="primary" size="small" icon={ArrowRight} disabled={!pendingConsent.consent_url} on:click={openConsent}>
							Approve in IVIA
						</Button>
						<Button kind="danger-tertiary" size="small" on:click={denyConsent}>Deny</Button>
					</div>
				</div>
			</div>
		</AgentTurn>
	{/if}
</ChatWorkspace>

<style>
	.empty-state {
		margin: auto 0;
		padding: 2rem;
		text-align: center;
		font-size: 15px;
		color: var(--ovi-text-helper);
	}

	/* Approval card — the amber human-in-the-loop card from the Use Case 3 design. */
	.approval {
		display: flex;
		align-items: flex-start;
		gap: 14px;
		padding: 14px 18px;
		border-radius: var(--ovi-radius-card);
		border: 1px solid var(--ovi-amber-border);
		background: var(--ovi-amber-soft);
	}

	.approval-icon {
		width: 34px;
		height: 34px;
		flex-shrink: 0;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ovi-card);
		color: var(--ovi-amber);
	}

	.approval-body {
		min-width: 0;
	}

	.approval-body p {
		margin: 3px 0 0;
		font-size: 14px;
		line-height: 1.5;
		color: var(--ovi-text-strong);
	}

	.approval-body .approval-title {
		margin: 0;
		font-size: 15px;
		font-weight: 600;
		color: var(--ovi-text-primary);
	}

	.approval-body .approval-details {
		margin-top: 8px;
		padding: 8px 10px;
		border-radius: 8px;
		border: 1px solid var(--ovi-hairline-strong);
		background: var(--ovi-card);
		font-size: 13px;
		overflow-wrap: anywhere;
	}

	.approval-body .approval-meta {
		margin-top: 8px;
		font-size: 12.5px;
		color: var(--ovi-amber);
	}

	.approval-actions {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-top: 12px;
	}

	.approval-actions :global(.bx--btn) {
		border-radius: var(--ovi-radius-pill);
	}
</style>
