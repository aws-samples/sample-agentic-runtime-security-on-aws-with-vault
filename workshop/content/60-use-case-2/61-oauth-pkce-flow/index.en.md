---
title: 'OAuth Authorization Code + PKCE Flow'
weight: 61
---

## Overview

In this module you open the Banking UI, authenticate as a test user through IBM Verify Access (IVIA), and inspect the JWT that the SvelteKit server-side code receives at the OAuth callback. You will observe how PKCE prevents authorization code interception attacks, and how the resulting JWT carries the claims that Vault's `jwt` auth method validates.

## What Is PKCE?

**Proof Key for Code Exchange (PKCE)** is an extension to the OAuth Authorization Code flow that prevents authorization code injection attacks. Without PKCE, an attacker who intercepts the authorization code can exchange it for a token at the token endpoint. PKCE closes this gap with a one-time cryptographic binding:

1. **Before redirecting to IVIA**, the Banking UI server generates a random `code_verifier` (43–128 characters, URL-safe).
2. It computes `code_challenge = BASE64URL(SHA-256(code_verifier))` using the `S256` method.
3. The authorization request to IVIA includes `code_challenge` and `code_challenge_method=S256`.
4. IVIA stores the challenge.
5. **When exchanging the code**, the Banking UI includes the original `code_verifier`. IVIA re-computes the challenge and compares — a mismatched verifier rejects the exchange.

The `code_verifier` never leaves the server-side session (stored in an `httpOnly` cookie). A browser-side attacker who intercepts the authorization code cannot use it without the verifier.

## Step 1 — Get the Banking UI URL

The Banking UI is exposed via an ALB Ingress in the `banking-app` namespace. Retrieve its hostname:

```bash
kubectl get ingress -n banking-app banking-ui-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open the URL in a browser:

```
http://<ALB_HOSTNAME>/
```

:::alert{header="HTTP only — lab environment" type="info"}
The ALB uses HTTP (not HTTPS) because ALB-generated hostnames cannot be registered in Route 53 for ACM certificate issuance. In a production deployment, use HTTPS with a custom domain. The workshop marks this clearly so attendees understand the lab constraint.
:::

## Step 2 — Authenticate as Oscar

On the Banking UI login page, you are redirected automatically to IVIA's login screen. Use the test user credentials:

- **Username:** `oscar`
- **Password:** (provided by your workshop facilitator or set during `ivia-configure.sh`)

After login, IVIA redirects the browser back to the Banking UI callback URL (`http://<ALB>/callback`). The SvelteKit server-side route handles the code exchange and stores the JWT in a server-side session.

## Step 3 — Inspect the Banking UI logs

The Banking UI logs the decoded JWT claims at the callback (without printing the raw token). View the logs:

```bash
kubectl logs -n banking-app -l app=banking-ui --tail=30
```

Look for a log line similar to:

```
INFO callback: jwt_claims sub=oscar@cdlbank.com aud=agent-uc2 azp=agent-uc2 exp=<timestamp>
```

Note:

- `sub` — the user's unique identity. This claim flows through to the MCP Server and from there into the Postgres `app.current_user_sub` session variable that activates Row-Level Security.
- `aud` — `agent-uc2`. This is the OAuth client ID that the Vault `jwt` auth role `uc2-jwt` validates against `bound_audiences`.
- `azp` — the authorized party. Set to the Banking UI client ID.

## Step 4 — Switch users: authenticate as Adriana

Log out (click **Logout** in the top-right corner), then log in as:

- **Username:** `adriana`
- **Password:** (provided by your workshop facilitator)

Observe that the Banking UI now shows Adriana's accounts and transactions — not Oscar's. The user `sub` claim changed, activating a different Row-Level Security filter in Postgres.

:::expand{header="Platform Track — IVIA OAuth client configuration and PKCE enforcement"}

The IVIA OAuth client `agent-uc2` is configured by `ivia-configure.sh` with these settings:

| Setting | Value | Why |
|---|---|---|
| `client_id` | `agent-uc2` | Matches Vault jwt role `bound_audiences` |
| `grant_types` | `authorization_code` | PKCE flow only — no implicit, no client_credentials |
| `pkce_required` | `true` | Rejects token requests without `code_verifier` |
| `redirect_uris` | `http://<ALB>/callback` | ALB hostname injected at configure time |
| `token_endpoint_auth_method` | `none` | Public client — no client_secret; PKCE is the proof |

IVIA's authorization endpoint URL pattern:

```
http://<IVIA_ALB>/pksc/sps/oauth/oauth20/authorize
  ?response_type=code
  &client_id=agent-uc2
  &redirect_uri=http%3A%2F%2F<UI_ALB>%2Fcallback
  &code_challenge=<BASE64URL_SHA256_verifier>
  &code_challenge_method=S256
  &scope=openid+profile
```

The SvelteKit `/login` server route generates the `code_verifier` using Node.js `crypto.randomBytes(32)`, computes the challenge, stores the verifier in an `httpOnly` session cookie, then redirects the browser to this URL. The browser never sees the `code_verifier` — it lives only on the server side, protecting against XSS-based token theft.

How the Banking UI maps to the SvelteKit file structure:

```
src/routes/
  +page.svelte          — Landing page (redirects to /login if no session)
  login/
    +server.ts          — Generates code_verifier, sets httpOnly cookie, redirects to IVIA
  callback/
    +server.ts          — Exchanges code + verifier for JWT, stores in server session
  logout/
    +server.ts          — Clears session, optionally revokes Vault lease
```
:::

:::expand{header="Agent Developer Track — JWT claims and how the agent uses them"}

The Banking Agent receives the user's JWT in the `Authorization: Bearer <token>` header of every API call from the Banking UI. The agent does **not** validate the JWT signature — that is Vault's responsibility. The agent treats the JWT as an opaque credential and forwards it to the MCP Server.

The MCP Server calls Vault's `jwt` auth endpoint:

```typescript
// vault-client.ts
async loginWithJwt(userJwt: string): Promise<string> {
  const response = await fetch(`${VAULT_ADDR}/v1/auth/jwt/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ role: 'uc2-jwt', jwt: userJwt }),
  });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(`Vault jwt login failed: ${data.errors?.join(', ')}`);
  }
  return data.auth.client_token;
}
```

Vault validates the JWT against IVIA's JWKS endpoint (fetched from the `oidc_discovery_url` configured in the jwt auth backend). Vault then maps the `sub` claim from the JWT to the Vault entity metadata — enabling per-user policy evaluation.

The `sub` claim value (e.g., `oscar@cdlbank.com`) is also passed directly to the Postgres session:

```typescript
// mcp-server tools handler
await client.query("SET app.current_user_sub = $1", [sub]);
const accounts = await client.query(
  "SELECT * FROM banking.accounts"  // RLS filters by app.current_user_sub
);
```

This is the complete chain: `sub` in JWT → Vault jwt login claim extraction → Postgres session variable → RLS predicate. Each link is visible in application code — no magic.
:::
