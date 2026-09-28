/**
 * hooks.server.ts — SvelteKit server hooks for the banking UI.
 *
 * The one place that decides whether a request is signed in. A sign-in is the
 * access_token cookie together with an id_token that has not expired. When the
 * access token is there but the id_token is missing, unreadable, or expired — by
 * the rule and clock leeway in lib/server/session-lifetime.ts, the same ones the
 * Audit Trace checks a sign-in by — the session is over:
 *   - every session cookie is cleared, with the attributes /logout clears them with;
 *   - a request under /api/ is answered 401 with JSON and is never redirected: a
 *     redirect would hand a sign-in page's HTML to a chat stream. The body carries a
 *     `sessionEnded` marker (lib/session-ended.ts), and the browser code that calls
 *     these routes goes to sign-in when it sees it. /api/ask is the exception: Use
 *     Case 1 needs no sign-in, so it carries on signed out;
 *   - anything else carries on signed out (locals.accessToken is null): the layout
 *     sends a page that needs a session to /, which starts sign-in; /ask works
 *     signed out; /logout still ends the IVIA session.
 *
 * Only `exp` is read here; the signature is not checked on every request. The
 * Audit Trace (lib/server/audit-trace/session.ts) and the Use Case 3 agent
 * (applications/uc3-agent/app/auth.py) verify the id_token themselves before they
 * act on it.
 */

import { json, type Cookies, type Handle } from '@sveltejs/kit';
import { sessionEndedBody, type SessionEndReason } from '$lib/session-ended';
import { SESSION_COOKIES, SESSION_COOKIE_OPTIONS, isExpired, readExp } from '$lib/server/session-lifetime';

// Under /api/, the routes that work without a sign-in. Matched like the layout's
// PUBLIC_PATHS: the path itself or anything below it.
const PUBLIC_API_PATHS = ['/api/ask'];

/** Why the id_token no longer carries a sign-in, or null while it does. */
function sessionEnd(idToken: string | undefined): SessionEndReason | null {
  const exp = readExp(idToken);
  if (exp === null) return 'unverifiable';
  return isExpired(exp) ? 'expired' : null;
}

function isUnder(path: string, prefix: string): boolean {
  return path === prefix || path.startsWith(prefix + '/');
}

/** The Set-Cookie values that clear every session cookie, byte for byte what /logout sends. */
function clearedSessionCookies(cookies: Cookies): string[] {
  return SESSION_COOKIES.map((name) => cookies.serialize(name, '', { ...SESSION_COOKIE_OPTIONS, maxAge: 0 }));
}

export const handle: Handle = async ({ event, resolve }) => {
  const accessToken = event.cookies.get('access_token') ?? null;
  const ended = accessToken ? sessionEnd(event.cookies.get('id_token')) : null;

  if (ended) {
    const path = event.url.pathname;
    if (isUnder(path, '/api') && !PUBLIC_API_PATHS.some((p) => isUnder(path, p))) {
      // A Response returned from the hook without resolve() does not carry the
      // cookies set through event.cookies, so the clearing headers go on it here.
      const res = json(sessionEndedBody(ended), { status: 401, headers: { 'Cache-Control': 'no-store' } });
      for (const cookie of clearedSessionCookies(event.cookies)) res.headers.append('set-cookie', cookie);
      return res;
    }
    for (const name of SESSION_COOKIES) event.cookies.delete(name, SESSION_COOKIE_OPTIONS);
    event.locals.accessToken = null;
    return resolve(event);
  }

  event.locals.accessToken = accessToken;
  return resolve(event);
};
