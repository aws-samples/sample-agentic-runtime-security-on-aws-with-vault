/**
 * agent-client.ts — Browser-side HTTP client for the banking agent.
 *
 * Calls the SvelteKit server-side proxy at /api/chat, which forwards
 * the request (with the user's JWT from httpOnly cookies) to the
 * cluster-internal banking-agent pod. The browser never calls the
 * agent directly — it can't reach cluster-internal services.
 */

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
  endpoint: string = '/api/chat'
): Promise<void> {
  try {
    const res = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
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
