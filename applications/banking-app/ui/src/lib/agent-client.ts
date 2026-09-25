/**
 * agent-client.ts — Browser-side HTTP client for the banking agent.
 *
 * Calls the SvelteKit server-side proxy at /api/chat, which forwards
 * the request (with the user's JWT from httpOnly cookies) to the
 * cluster-internal banking-agent pod. The browser never calls the
 * agent directly — it can't reach cluster-internal services.
 *
 * Two kinds of frame arrive (see $lib/agent-events):
 *   - the legacy frames (tool_planning, delta, end, error) always go to
 *     `onMessage`, exactly as before;
 *   - every other event (agent:narration, tool_call, agent:credential, ...) goes
 *     to `onEvent` when the caller passes one, and to `onMessage` otherwise, so a
 *     caller that passes no `onEvent` sees what it always saw.
 */

import type { AgentEvent, LegacyAgentEvent } from '$lib/agent-events';

const LEGACY_TYPES: ReadonlySet<string> = new Set<LegacyAgentEvent['type']>(['tool_planning', 'delta', 'end', 'error']);

/** The `error` sentence of a chat route's JSON failure body, or undefined for any other body. */
function routeError(body: string): string | undefined {
  try {
    const parsed: unknown = JSON.parse(body);
    if (parsed && typeof parsed === 'object' && 'error' in parsed) {
      const error = (parsed as { error: unknown }).error;
      if (typeof error === 'string' && error !== '') return error;
    }
  } catch {
    // Not JSON: the caller shows the body as it came.
  }
  return undefined;
}

export interface ChatResponse {
  role: string;
  content: string;
  type?: string;
}

export async function sendChatMessage(
  message: string,
  _jwt: string,
  sessionId: string,
  onMessage: (chunk: ChatResponse) => void,
  onError: (error: string) => void,
  endpoint: string = '/api/chat',
  onEvent?: (event: AgentEvent) => void
): Promise<void> {
  try {
    const res = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message, sessionId }),
    });

    if (!res.ok) {
      // The chat routes answer a failure with JSON { error }, a sentence written for the
      // person reading the chat; show that sentence. Any other body is shown as it came.
      const text = await res.text();
      onError(routeError(text) ?? `Agent request failed [${res.status}]: ${text}`);
      return;
    }

    if (!res.body) {
      onError('No response body from agent');
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder('utf-8');
    let buffer = '';
    // Every answer finishes with an `end` frame. A stream that closes without
    // one was cut short (the agent died mid-answer), and the caller must hear
    // about it: `end` or onError is what releases the chat.
    let sawEnd = false;

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';

      for (const line of lines) {
        if (line.startsWith('data: ')) {
          try {
            const data = JSON.parse(line.substring(6)) as ChatResponse;
            if (data.type === 'end') sawEnd = true;
            if (onEvent && typeof data.type === 'string' && !LEGACY_TYPES.has(data.type)) {
              onEvent(data as unknown as AgentEvent);
            } else {
              onMessage(data);
            }
          } catch {
            // Skip malformed SSE lines
          }
        }
      }
    }

    if (!sawEnd) {
      onError('The agent stopped before its answer was complete. Please try again.');
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    onError(`Agent connection failed: ${msg}`);
  }
}
