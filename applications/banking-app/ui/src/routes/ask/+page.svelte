<!--
  /ask — Public Use Case 1 demo page.

  Non-personalized, read-only agent. No sign-in: the uc1-agent authenticates
  itself to Vault with its Kubernetes workload identity and obtains JIT
  credentials to read the Bedrock Knowledge Base and Postgres. There is no
  end-user token here — that is the entire point of Use Case 1.

  The browser POSTs { message } to /api/ask (via $lib/agent-client), which relays
  the uc1-agent's event stream. Each turn's events are kept per turn
  ($lib/turn-events.svelte): the tool chips, the result cards ($lib/answer-cards)
  and the Agent Log are drawn from them as they arrive. The answer is the legacy `delta` frame,
  so an agent event never becomes a chat bubble.

  The left navigation comes from the root layout; signed-out visitors see
  "Not signed in" and a Sign in link there.
-->
<script lang="ts">
	import { InlineNotification } from 'carbon-components-svelte';
	import { sendChatMessage } from '$lib/agent-client';
	import { countEntries } from '$lib/agent-log';
	import { createTurnLog, type Turn } from '$lib/turn-events.svelte';
	import { toolCallsOf } from '$lib/accounts-turn';
	import { answerCardsOf } from '$lib/answer-cards';
	import ChatWorkspace, { type Suggestion } from '$lib/components/chat/ChatWorkspace.svelte';
	import UserMessage from '$lib/components/chat/UserMessage.svelte';
	import AgentTurn from '$lib/components/chat/AgentTurn.svelte';
	import AnswerCard from '$lib/components/chat/AnswerCard.svelte';
	import ToolCallChip from '$lib/components/chat/ToolCallChip.svelte';
	import AnswerCards from '$lib/components/chat/AnswerCards.svelte';
	import FormattedAnswer from '$lib/components/chat/FormattedAnswer.svelte';
	import AgentLogPanel from '$lib/components/activity/AgentLogPanel.svelte';
	import SecurityFlowPanel from '$lib/components/activity/SecurityFlowPanel.svelte';
	import AuditTraceCard from '$lib/components/activity/AuditTraceCard.svelte';

	const log = createTurnLog();
	/** Which right-hand panel is open. Shared convention with the other chat pages. */
	let openPanel = $state<'log' | 'flow' | null>(null);
	/** The answer text and any error of each turn, by Turn id. */
	let replies = $state<Record<string, { answer: string; error?: string }>>({});
	let inputMessage = $state('');
	let isLoading = $state(false);

	const entryCount = $derived(countEntries(log.turns));

	// Each answer as the approved #65 board draws it: a chip per tool call, a card of what each
	// tool returned with the credential that read it ($lib/answer-cards), then the Audit Trace
	// card and the formatted answer.
	const views = $derived(
		log.turns.map((turn) => ({
			turn,
			tools: toolCallsOf(turn.events, turn.done),
			cards: answerCardsOf(turn.events),
			reply: replies[turn.id]
		}))
	);

	// Auto-scroll the message list to the newest content: a new chip, card or answer.
	let messagesEl: HTMLDivElement | undefined = $state();
	$effect(() => {
		void views;
		void isLoading;
		messagesEl?.scrollTo({ top: messagesEl.scrollHeight, behavior: 'smooth' });
	});

	const prompts = [
		'Using the knowledge base, summarize the employee PTO policy.',
		'What is the remote work policy?',
		'How many vacation days do new employees get?'
	];

	const suggestions: Suggestion[] = prompts.map((s) => ({ label: s, onselect: () => sendSuggestion(s) }));

	function sendSuggestion(s: string) {
		if (isLoading) return;
		inputMessage = s;
		sendMessage();
	}

	function toggleLog() {
		openPanel = openPanel === 'log' ? null : 'log';
	}

	function toggleFlow() {
		openPanel = openPanel === 'flow' ? null : 'flow';
	}

	async function sendMessage() {
		const query = inputMessage.trim();
		if (!query || isLoading) return;

		inputMessage = '';
		isLoading = true;
		const turn: Turn = log.begin(query);
		replies[turn.id] = { answer: '' };
		const reply = replies[turn.id];

		await sendChatMessage(
			query,
			'',
			turn.id,
			(chunk) => {
				if (chunk.type === 'delta' && chunk.content) reply.answer += chunk.content;
				else if (chunk.type === 'error') reply.error = chunk.content || 'The agent reported an error.';
			},
			(err) => {
				reply.error ??= err;
			},
			'/api/ask',
			(event) => log.push(event, turn)
		);
		// A turn that failed shows its error in the Agent Log too.
		if (reply.error === undefined) log.end(turn);
		else log.fail(reply.error, turn);
		isLoading = false;
	}
</script>

<svelte:head>
	<title>Knowledge Agent — OscarVault International</title>
</svelte:head>

{#snippet agentIcon()}
	<svg width="16" height="16" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
		<path d="M4 3h9l3 3v11H4z"></path>
	</svg>
{/snippet}

<ChatWorkspace
	title="Knowledge Agent"
	subtitle="Public · no sign-in · the agent proves its own identity to Vault"
	statusLabel="Workload identity"
	agentLogOpen={openPanel === 'log'}
	agentLogCount={entryCount}
	agentLogControls="agent-log"
	onAgentLogToggle={toggleLog}
	securityFlowOpen={openPanel === 'flow'}
	securityFlowControls="security-flow"
	onSecurityFlowToggle={log.turns.length > 0 ? toggleFlow : undefined}
	bind:messagesEl
	{suggestions}
	bind:value={inputMessage}
	busy={isLoading}
	inputId="ask-message"
	inputLabel="Ask the knowledge agent"
	placeholder="Ask about company policy…"
	onsend={sendMessage}
	hint="Enter to send · Shift+Enter for new line · No sign-in: this agent reads the policy knowledge base and can run read-only database queries"
>
	{#snippet icon()}
		<svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
			<path d="M4 3h9l3 3v11H4z"></path>
			<path d="M7 9h6M7 12h6"></path>
		</svg>
	{/snippet}

	{#snippet panel()}
		{#if openPanel === 'log'}
			<AgentLogPanel
				id="agent-log"
				turns={log.turns}
				systems="Kubernetes auth · Vault · Bedrock"
				onclose={() => (openPanel = null)}
			/>
		{:else if openPanel === 'flow'}
			<SecurityFlowPanel id="security-flow" useCase={1} turn={log.turns.at(-1)} onclose={() => (openPanel = null)} />
		{/if}
	{/snippet}

	{#if views.length === 0}
		<p class="empty-state">Ask a question about company policies, or pick a starter prompt below.</p>
	{/if}

	{#each views as { turn, tools, cards, reply } (turn.id)}
		<UserMessage>{turn.question}</UserMessage>
		<AgentTurn label="Knowledge Agent" icon={agentIcon}>
			{#each tools as tool (tool.id)}
				<ToolCallChip name={tool.name} status={tool.status} durationMs={tool.durationMs} />
			{/each}
			<AnswerCards {cards} />
			{#if reply?.error}
				<InlineNotification kind="error" lowContrast hideCloseButton title="Error" subtitle={reply.error} />
			{/if}
			{#if turn.done && reply?.answer}
				<AuditTraceCard useCase={1} {turn} />
			{/if}
			{#if reply?.answer}
				<FormattedAnswer text={reply.answer} />
			{:else if !turn.done}
				<AnswerCard pending>Thinking…</AnswerCard>
			{:else if !reply?.error}
				<AnswerCard>(empty answer)</AnswerCard>
			{/if}
		</AgentTurn>
	{/each}
</ChatWorkspace>

<style>
	.empty-state {
		margin: auto 0;
		padding: 2rem;
		text-align: center;
		font-size: 15px;
		color: var(--ovi-text-helper);
	}
</style>
