/**
 * athena.ts — one parameterised query against the audit_correlation view.
 *
 * The Audit Trace card asks: "what did every system record for this refund?". The
 * answer is the audit_correlation rows for one request ID — and only if that request
 * was approved by the person asking. Both conditions are in the SQL:
 *
 *   WHERE request_id = ? AND user_approved_sub = ?
 *
 * `user_approved_sub` is the sub the Use Case 3 agent verified from the approver's own
 * id_token before it wrote the approval anchor (applications/uc3-agent/app/agent.py);
 * the second value is the sub this server verified from the caller's id_token
 * (session.ts). Another user's request ID therefore matches no row — the same answer
 * as a request whose records have not landed yet, so the endpoint reveals nothing
 * about requests that are not yours.
 *
 * Both values travel as Athena execution parameters, never spliced into the SQL, and
 * each is checked against a strict pattern before it is sent.
 *
 * AWS access is the audit-reader role's 15-minute keys that Vault issues to this pod
 * (vault-aws.ts). That role can run queries only in the `workshop` work group and read
 * only the audit tables; the work group fixes where results are written, so this code
 * never names an output location.
 */

import {
	AthenaClient,
	GetQueryExecutionCommand,
	GetQueryResultsCommand,
	StartQueryExecutionCommand,
	StopQueryExecutionCommand
} from '@aws-sdk/client-athena';
import { env } from '$env/dynamic/private';
import {
	AUDIT_CORRELATION_COLUMNS,
	REQUEST_ID_PATTERN,
	type AuditCorrelationColumn,
	type AuditCorrelationRow
} from '$lib/audit-trace';
import { auditReaderCredentials, forgetAuditReaderCredentials } from './vault-aws';

/** The view the query reads (infrastructure/modules/observability, output audit_correlation_view_name). */
const VIEW = 'audit_correlation';

/** A refund has one row per write; 20 is far above any real refund and bounds the reply. */
const ROW_LIMIT = 20;

/** IVIA subs in this workshop are user names (oscar, jaime). Anything else is refused. */
const SUB_PATTERN = /^[A-Za-z0-9._@-]{1,128}$/;

/** How long one query may run before it is stopped and reported as a timeout. */
const QUERY_DEADLINE_MS = 25_000;

const QUERY =
	`SELECT ${AUDIT_CORRELATION_COLUMNS.join(', ')} FROM ${VIEW} ` +
	`WHERE request_id = ? AND user_approved_sub = ? LIMIT ${ROW_LIMIT}`;

export type AuditQueryFailure = 'misconfigured' | 'credentials' | 'denied' | 'failed' | 'timeout';

export class AuditQueryError extends Error {
	constructor(
		readonly failure: AuditQueryFailure,
		message: string
	) {
		super(message);
		this.name = 'AuditQueryError';
	}
}

let client: AthenaClient | null = null;

function athena(): AthenaClient {
	const region = env.AWS_REGION;
	if (!region) throw new AuditQueryError('misconfigured', 'AWS_REGION is not set');
	if (!client) client = new AthenaClient({ region, credentials: auditReaderCredentials });
	return client;
}

function config(): { workGroup: string; database: string } {
	const workGroup = env.ATHENA_WORKGROUP;
	const database = env.AUDIT_GLUE_DATABASE;
	if (!workGroup || !database) {
		throw new AuditQueryError('misconfigured', 'ATHENA_WORKGROUP and AUDIT_GLUE_DATABASE must be set');
	}
	return { workGroup, database };
}

/** An Athena execution parameter is a SQL literal: a string value goes in single quotes. */
function literal(value: string): string {
	return `'${value.replaceAll("'", "''")}'`;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** AWS rejected the keys themselves (expired, revoked): drop them so the next call issues fresh ones. */
function isCredentialRejection(err: unknown): boolean {
	const name = (err as { name?: unknown })?.name;
	return (
		name === 'ExpiredTokenException' ||
		name === 'UnrecognizedClientException' ||
		name === 'InvalidSignatureException' ||
		name === 'InvalidClientTokenId'
	);
}

function classify(err: unknown): AuditQueryError {
	if (err instanceof AuditQueryError) return err;
	const name = (err as { name?: unknown })?.name;
	if (name === 'VaultCredentialError') {
		return new AuditQueryError('credentials', (err as Error).message);
	}
	if (isCredentialRejection(err)) {
		forgetAuditReaderCredentials();
		return new AuditQueryError('credentials', `AWS rejected the audit-reader keys (${String(name)})`);
	}
	if (name === 'AccessDeniedException') {
		return new AuditQueryError('denied', 'the audit-reader role is not allowed to run this query');
	}
	const message = err instanceof Error ? err.message : String(err);
	return new AuditQueryError('failed', message);
}

async function waitForQuery(queryExecutionId: string, deadline: number): Promise<void> {
	let delay = 250;
	for (;;) {
		const { QueryExecution } = await athena().send(new GetQueryExecutionCommand({ QueryExecutionId: queryExecutionId }));
		const state = QueryExecution?.Status?.State;
		if (state === 'SUCCEEDED') return;
		if (state === 'FAILED' || state === 'CANCELLED') {
			const reason = QueryExecution?.Status?.StateChangeReason ?? state;
			throw new AuditQueryError('failed', `Athena query ${state.toLowerCase()}: ${reason}`);
		}
		if (Date.now() + delay > deadline) {
			await athena()
				.send(new StopQueryExecutionCommand({ QueryExecutionId: queryExecutionId }))
				.catch(() => undefined);
			throw new AuditQueryError('timeout', `Athena query did not finish within ${QUERY_DEADLINE_MS / 1000} s`);
		}
		await sleep(delay);
		delay = Math.min(delay * 2, 2_000);
	}
}

async function readRows(queryExecutionId: string): Promise<AuditCorrelationRow[]> {
	const { ResultSet } = await athena().send(
		new GetQueryResultsCommand({ QueryExecutionId: queryExecutionId, MaxResults: ROW_LIMIT + 1 })
	);
	const names = (ResultSet?.ResultSetMetadata?.ColumnInfo ?? []).map((c) => c.Name ?? '');
	const missing = AUDIT_CORRELATION_COLUMNS.filter((c) => !names.includes(c));
	if (missing.length > 0) {
		throw new AuditQueryError('failed', `audit_correlation returned no column ${missing.join(', ')}`);
	}
	// The first row of a SELECT's result set repeats the column names.
	const dataRows = (ResultSet?.Rows ?? []).slice(1);
	return dataRows.map((row) => {
		const values = row.Data ?? [];
		const out = {} as AuditCorrelationRow;
		for (const column of AUDIT_CORRELATION_COLUMNS) {
			const value = values[names.indexOf(column)]?.VarCharValue;
			out[column as AuditCorrelationColumn] = value === undefined || value === '' ? null : value;
		}
		return out;
	});
}

/**
 * The audit_correlation rows for `requestId` that `sub` approved. An empty list means
 * either the records have not reached Athena yet or the request is not `sub`'s.
 */
export async function queryAuditCorrelation(requestId: string, sub: string): Promise<AuditCorrelationRow[]> {
	if (!REQUEST_ID_PATTERN.test(requestId)) throw new AuditQueryError('failed', 'request ID is not a UUID');
	if (!SUB_PATTERN.test(sub)) throw new AuditQueryError('failed', 'session sub has an unexpected form');
	const { workGroup, database } = config();
	const deadline = Date.now() + QUERY_DEADLINE_MS;
	try {
		const { QueryExecutionId } = await athena().send(
			new StartQueryExecutionCommand({
				QueryString: QUERY,
				QueryExecutionContext: { Catalog: 'AwsDataCatalog', Database: database },
				WorkGroup: workGroup,
				ExecutionParameters: [literal(requestId), literal(sub)]
			})
		);
		if (!QueryExecutionId) throw new AuditQueryError('failed', 'Athena returned no query execution ID');
		await waitForQuery(QueryExecutionId, deadline);
		return await readRows(QueryExecutionId);
	} catch (err) {
		throw classify(err);
	}
}
