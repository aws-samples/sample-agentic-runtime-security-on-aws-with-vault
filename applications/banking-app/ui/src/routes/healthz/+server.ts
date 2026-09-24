/**
 * healthz — liveness endpoint for the ALB target-group health check.
 *
 * This is a +server.ts ENDPOINT, not a page, and that is load-bearing:
 * SvelteKit runs +layout.server.ts only for page requests, so the session
 * guard there (which 302s every non-public path to /) never sees this route.
 * A page-based health route would inherit that redirect and the health check
 * would measure nothing.
 *
 * It answers 200 from process state alone — no Vault, no Postgres, no
 * Bedrock, no IVIA. The ALB is asking "is this process serving HTTP", and
 * anything broader would take the banking UI out of the load balancer
 * whenever a dependency further down was having a bad minute.
 */

import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = () => json({ status: 'ok' });
