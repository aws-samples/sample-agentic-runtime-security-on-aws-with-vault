<!--
  AccountsCard — "Your accounts": the rows get_accounts read from Postgres under row-level
  security (banking.accounts, applications/banking-app/db/seed.sql), with a footer naming the
  database credential Vault issued to read them.

  The footer shows only what the turn's stream reported ($lib/accounts-turn). A value the
  stream did not carry is shown as "not observed", never guessed.
-->
<script lang="ts">
	import { formatAccountType, formatBalance, type AccountsCardView } from '$lib/accounts-turn';

	interface Props {
		accounts: AccountsCardView['accounts'];
		credential?: AccountsCardView['credential'];
		/** Whose accounts they are: the signed-in person's display name. */
		owner?: string;
	}

	let { accounts, credential, owner }: Props = $props();

	const count = $derived(`${accounts.length} ${accounts.length === 1 ? 'account' : 'accounts'}${owner ? ` for ${owner}` : ''}`);
	// The database role is the last segment of the Vault path, e.g. database/creds/uc2-personal-readonly.
	const role = $derived(credential?.vaultPath?.split('/').at(-1) || undefined);
</script>

<div class="accounts">
	<div class="accounts-header">
		<div>
			<p class="accounts-title">Your accounts</p>
			<p class="accounts-subtitle">{count}</p>
		</div>
		<span class="accounts-tag">Row-level security</span>
	</div>
	<div class="accounts-scroll">
		<table>
			<thead>
				<tr><th scope="col">Account</th><th scope="col">Type</th><th scope="col" class="balance">Balance</th></tr>
			</thead>
			<tbody>
				{#each accounts as account, i (i)}
					<tr>
						<td class="mono">{account.accountNumber}</td>
						<td>{formatAccountType(account.accountType)}</td>
						<td class="num">{formatBalance(account.balance)}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
	<div class="accounts-footer">
		<span>db role {role ?? 'not observed'} · {credential?.vaultPath ?? 'Vault path not observed'}</span>
		<span>lease {credential?.leaseId ?? 'not observed'} · {typeof credential?.ttlSeconds === 'number' ? `${credential.ttlSeconds}s TTL` : 'TTL not observed'}</span>
	</div>
</div>

<style>
	/* The approved board's card (.card, .cardhd, .ctitle, .csub, .tag, table, .cardft). */
	.accounts {
		overflow: hidden;
		border-radius: var(--ovi-radius-card);
		border: 1px solid var(--ovi-hairline);
		background: var(--ovi-card);
		box-shadow: var(--ovi-card-shadow);
	}

	.accounts-header {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 14px 18px;
	}

	/* line-height: normal, as on the board; Carbon gives <p> and table cells their own. */
	.accounts-title {
		margin: 0;
		font-weight: 600;
		font-size: 15.5px;
		line-height: normal;
		color: var(--ovi-text-primary);
	}

	.accounts-subtitle {
		margin: 0;
		font-size: 13px;
		line-height: normal;
		color: var(--ovi-text-helper);
	}

	.accounts-tag {
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

	.accounts-scroll {
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

	th.balance {
		text-align: right;
	}

	td {
		padding: 11px 18px;
		border-top: 1px solid var(--ovi-hairline);
		color: var(--ovi-text-primary);
		line-height: normal;
	}

	td.mono {
		font: 13px var(--ovi-font-mono);
		color: var(--ovi-text-strong);
	}

	td.num {
		text-align: right;
		font-family: var(--ovi-font-mono);
		white-space: nowrap;
	}

	/* Real lease ids are long: the two halves wrap onto their own lines rather than being cut. */
	.accounts-footer {
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
