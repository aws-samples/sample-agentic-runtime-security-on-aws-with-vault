/**
 * agent-client.ts — HTTP client for the banking agent pod.
 *
 * Forwards user JWT in Authorization: Bearer header on every request.
 * The agent never stores the JWT — it extracts it from each inbound request
 * and forwards it to the MCP server for Vault authentication.
 *
 * Security note:
 *   - The JWT is a Bearer credential; HTTPS is required in production.
 *     Workshop uses HTTP (HTTP-only ALB hostnames per CONTEXT decision).
 *     Workshop content documents this as lab-only.
 */

import { env } from '$env/dynamic/public';

export interface ChatResponse {
  role: string;
  content: string;
  type?: string;
}

/**
 * Send a chat message to the agent pod with the user's JWT.
 *
 * @param message    - User's natural-language query
 * @param jwt        - IVIA access token from session cookie
 * @param sessionId  - Session identifier for conversation history
 * @param onMessage  - Callback invoked for each SSE chunk
 * @param onError    - Callback invoked on error
 */
export async function sendChatMessage(
  message: string,
  jwt: string,
  sessionId: string,
  onMessage: (chunk: ChatResponse) => void,
  onError: (error: string) => void
): Promise<void> {
  const agentUrl = env.PUBLIC_AGENT_URL ?? '';

  if (!agentUrl) {
    onError('PUBLIC_AGENT_URL is not configured');
    return;
  }

  const url = `${agentUrl}/chat`;

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // Forward user JWT — agent validates this and passes it to MCP server
        Authorization: `Bearer ${jwt}`,
      },
      body: JSON.stringify({ message, sessionId }),
    });

    if (!res.ok) {
      const text = await res.text();
      onError(`Agent request failed [${res.status}]: ${text}`);
      return;
    }

    if (!res.body) {
      onError('No response body from agent');
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder('utf-8');
    let buffer = '';

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
            onMessage(data);
          } catch {
            // Skip malformed SSE lines
          }
        }
      }
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    onError(`Agent connection failed: ${msg}`);
  }
}
