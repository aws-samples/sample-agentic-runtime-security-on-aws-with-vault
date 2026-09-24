<!--
  /ask — Public Use Case 1 demo page.

  Non-personalized, read-only agent. No sign-in: the uc1-agent authenticates
  itself to Vault with its Kubernetes workload identity and obtains JIT
  credentials to read the Bedrock Knowledge Base and Postgres. There is no
  end-user token here — that is the entire point of Use Case 1.

  The browser POSTs { query } to /api/ask, which proxies to uc1-agent-svc and
  returns { answer, sources, credential_metadata }.

  The left navigation comes from the root layout; signed-out visitors see
  "Not signed in" and a Sign in link there.
-->
<script lang="ts">
	import { InlineNotification } from 'carbon-components-svelte';
	import ChatWorkspace, { type Suggestion } from '$lib/components/chat/ChatWorkspace.svelte';
	import UserMessage from '$lib/components/chat/UserMessage.svelte';
	import AgentTurn from '$lib/components/chat/AgentTurn.svelte';
	import AnswerCard from '$lib/components/chat/AnswerCard.svelte';

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
	bind:messagesEl
	{suggestions}
	bind:value={inputMessage}
	busy={isLoading}
	inputId="ask-message"
	inputLabel="Ask the knowledge agent"
	placeholder="Ask about company policy…"
	onsend={sendMessage}
	hint="Enter to send · Shift+Enter for new line · No sign-in: this agent reads company policy only"
>
	{#snippet icon()}
		<svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
			<path d="M4 3h9l3 3v11H4z"></path>
			<path d="M7 9h6M7 12h6"></path>
		</svg>
	{/snippet}

	{#if messages.length === 0}
		<p class="empty-state">Ask a question about company policies, or pick a starter prompt below.</p>
	{/if}

	{#each messages as msg}
		{#if msg.role === 'user'}
			<UserMessage>{msg.content}</UserMessage>
		{:else}
			<AgentTurn label="Knowledge Agent" icon={agentIcon}>
				{#if msg.role === 'error'}
					<InlineNotification kind="error" lowContrast hideCloseButton title="Error" subtitle={msg.content} />
				{:else}
					<AnswerCard>{msg.content}</AnswerCard>
				{/if}
			</AgentTurn>
		{/if}
	{/each}

	{#if isLoading}
		<AgentTurn label="Knowledge Agent" icon={agentIcon}>
			<AnswerCard pending>Thinking…</AnswerCard>
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
</style>
