<!--
  SourcesCard — the knowledge-base passages an answer came from: document and relevance, with
  a footer naming the Vault role and the short-lived AWS credentials the retrieval used.

  The footer shows only what the turn's stream reported. A value the stream did not carry is
  shown as "not observed", never guessed.
-->
<script module lang="ts">
	export interface Source {
		document: string;
		score?: number;
	}
</script>

<script lang="ts">
	interface Props {
		sources: Source[];
		/** The Vault role the agent logged in with (agent:audit_seed). */
		vaultRole?: string;
		/** Where the retrieval's AWS credentials came from, e.g. "aws/sts/bedrock-reader". */
		vaultPath?: string;
		/** Their lifetime in seconds, as Vault reported it. */
		ttlSeconds?: number;
	}

	let { sources, vaultRole, vaultPath, ttlSeconds }: Props = $props();
</script>

<div class="sources">
	<div class="sources-header">
		<div>
			<p class="sources-title">Sources</p>
			<p class="sources-subtitle">Retrieved from the Bedrock Knowledge Base</p>
		</div>
		<span class="sources-tag">Just-in-time access</span>
	</div>
	<div class="sources-scroll">
		<table>
			<thead>
				<tr><th scope="col">Document</th><th scope="col" class="num">Relevance</th></tr>
			</thead>
			<tbody>
				{#each sources as source, i (i)}
					<tr>
						<td class="mono">{source.document}</td>
						<td class="num">{typeof source.score === 'number' ? source.score.toFixed(2) : '—'}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
	<div class="sources-footer">
		<span>vault role {vaultRole ?? 'not observed'} · {vaultPath ?? 'credential path not observed'}</span>
		<span>STS credentials · {typeof ttlSeconds === 'number' ? `${ttlSeconds}s` : 'lifetime not observed'}</span>
	</div>
</div>

<style>
	.sources {
		overflow: hidden;
		border-radius: var(--ovi-radius-card);
		border: 1px solid var(--ovi-hairline);
		background: var(--ovi-card);
		box-shadow: var(--ovi-card-shadow);
	}

	.sources-header {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 14px 18px;
	}

	.sources-title {
		margin: 0;
		font-weight: 600;
		font-size: 15.5px;
		color: var(--ovi-text-primary);
	}

	.sources-subtitle {
		margin: 0;
		font-size: 13px;
		color: var(--ovi-text-helper);
	}

	.sources-tag {
		margin-left: auto;
		padding: 4px 10px;
		border-radius: var(--ovi-radius-pill);
		background: rgba(8, 189, 186, 0.12);
		color: var(--ovi-teal-deep);
		font: 600 11px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		white-space: nowrap;
	}

	.sources-scroll {
		overflow-x: auto;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 14px;
	}

	th {
		padding: 8px 18px;
		background: var(--ovi-surface-bg);
		color: var(--ovi-text-helper);
		font: 600 11px var(--ovi-font-condensed);
		letter-spacing: 0.08em;
		text-transform: uppercase;
		text-align: left;
	}

	td {
		padding: 11px 18px;
		border-top: 1px solid var(--ovi-hairline);
		color: var(--ovi-text-primary);
	}

	td.mono {
		font: 13px var(--ovi-font-mono);
		color: var(--ovi-text-strong);
		overflow-wrap: anywhere;
	}

	.num {
		text-align: right;
		font-family: var(--ovi-font-mono);
		white-space: nowrap;
	}

	.sources-footer {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		gap: 4px 12px;
		padding: 9px 18px;
		border-top: 1px solid var(--ovi-hairline);
		background: var(--ovi-surface-bg);
		font: 12px var(--ovi-font-mono);
		color: var(--ovi-text-helper);
		overflow-wrap: anywhere;
	}
</style>
