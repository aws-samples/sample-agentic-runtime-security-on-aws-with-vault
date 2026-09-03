---
title: 'OAuth Login Flow'
weight: 61
---

## Overview

In this module you open the OscarVault Banking UI, sign in with your LDAP credentials at the IBM Verify Identity Access (IVIA) login page, and observe how the **OAuth Authorization Code + PKCE** flow delivers a JWT to the SvelteKit server. You will see how the JWT carries the `sub` claim that Vault's **OAuth resource server** validates — the MCP Server presents that JWT directly via the `X-Vault-Token` header — and that PostgreSQL Row-Level Security uses to filter rows.

## Request Flow

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {
  'primaryColor': '#d0e2ff',
  'primaryTextColor': '#161616',
  'primaryBorderColor': '#0f62fe',
  'lineColor': '#0f62fe',
  'secondaryColor': '#bae6ff',
  'tertiaryColor': '#f4f4f4',
  'noteBkgColor': '#e8daff',
  'noteTextColor': '#161616',
  'noteBorderColor': '#8a3ffc',
  'actorBkg': '#d0e2ff',
  'actorBorder': '#0f62fe',
  'actorTextColor': '#161616',
  'signalColor': '#161616',
  'signalTextColor': '#161616',
  'labelBoxBkgColor': '#d0e2ff',
  'labelBoxBorderColor': '#0f62fe',
  'labelTextColor': '#161616',
  'loopTextColor': '#161616',
  'activationBorderColor': '#0f62fe',
  'activationBkgColor': '#edf5ff',
  'sequenceNumberColor': '#ffffff'
}}}%%
sequenceDiagram
    autonumber
    actor User
    participant UI as Banking UI<br/>(SvelteKit)
    participant WRP as IVIA WebSEAL<br/>Reverse Proxy
    participant OP as IVIA OIDC<br/>Provider
    participant LDAP as OpenLDAP
    participant Agent as Banking Agent<br/>(Strands SDK)
    participant MCP as MCP Server<br/>(Express)
    participant Vault as HashiCorp<br/>Vault
    participant RDS as PostgreSQL<br/>(RDS + RLS)

    rect rgba(208, 226, 255, 0.3)
    Note over User,LDAP: Authentication — Authorization Code + PKCE
    User->>UI: GET /
    UI->>UI: Generate code_verifier + code_challenge (S256)
    UI->>UI: Set pkce cookie {codeVerifier, state}
    UI-->>User: 302 to IVIA /oauth2/authorize?code_challenge=...
    User->>WRP: GET /isvaop/oauth2/authorize
    WRP-->>User: Login page (no WebSEAL session)
    User->>WRP: POST username + password
    WRP->>LDAP: LDAP bind cn=oscar,dc=ibm,dc=com
    LDAP-->>WRP: Bind OK
    WRP->>WRP: Create WebSEAL session
    WRP->>OP: Proxy /oauth2/authorize + iv-user header
    OP->>OP: Resolve authenticated user to sub
    OP-->>User: 302 to /callback?code=...&state=...
    User->>UI: GET /callback?code=...
    UI->>UI: Validate state matches pkce.state
    UI->>OP: POST /oauth2/token (in-cluster DNS)<br/>code, code_verifier, Basic auth
    OP->>OP: Pre-token rule stamps act.sub=agent-uc2
    OP-->>UI: access_token (sub + act.sub) + id_token (sub only)
    UI->>UI: Store tokens in httpOnly cookies
    UI-->>User: 302 to /dashboard
    end

    rect rgba(186, 230, 255, 0.3)
    Note over User,RDS: Banking query — identity propagation
    User->>UI: "What are my accounts?"
    UI->>Agent: POST /chat + Authorization: Bearer access_token
    Agent->>Agent: Extract JWT from header
    Agent->>MCP: JSON-RPC tools/call get_accounts<br/>Authorization: Bearer access_token
    Note over Agent,MCP: The tool takes no arguments —<br/>identity travels in the header alone
    MCP->>MCP: Decode header JWT → read sub claim (for RLS only)

    MCP->>Vault: GET /v1/database/creds/uc2-personal-readonly<br/>X-Vault-Token: IVIA JWT (no login round-trip)
    Vault->>OP: Validate JWT signature via JWKS
    OP-->>Vault: Public key confirmation
    Vault->>Vault: Resolve sub (human) + act.sub=agent-uc2 (Agent Registry)<br/>OBO: uc2-human-baseline intersect uc2-agent-ceiling
    Vault->>RDS: CREATE ROLE with 15-min TTL
    Vault-->>MCP: JIT credentials {username, password}

    MCP->>RDS: Connect with JIT creds
    MCP->>RDS: set_config('app.current_user_sub', 'oscar')
    MCP->>RDS: SELECT * FROM accounts
    RDS->>RDS: RLS filters rows WHERE owner_sub = 'oscar'
    RDS-->>MCP: Oscar's accounts only
    end

    MCP-->>Agent: Tool result (accounts JSON)
    Agent->>Agent: LLM formats response
    Agent-->>UI: SSE stream with formatted answer
    UI-->>User: "Checking: $4,250 · Savings: $18,750"

    rect rgba(167, 240, 186, 0.3)
    Note over MCP,RDS: Credential lifecycle
    MCP->>Vault: POST /v1/sys/leases/revoke<br/>X-Vault-Token: MCP server's own k8s-auth token
    Vault->>RDS: DROP ROLE (immediately, not at TTL)
    end
```

**Step-by-step breakdown:**

1. The user opens the Banking UI URL. The SvelteKit server load on `/` sees no `access_token` cookie, generates a PKCE pair (`code_verifier` + `code_challenge` via S256), persists `codeVerifier` and CSRF `state` to a short-lived `pkce` cookie, and 302s the browser to IVIA `/oauth2/authorize` with the public `code_challenge` and `state`.
2. The WebSEAL Reverse Proxy intercepts the unauthenticated request to `/isvaop/oauth2/authorize` and serves its built-in login page.
3. The user submits username + password to WebSEAL. WebSEAL performs an LDAP bind against OpenLDAP (`cn=<user>,dc=ibm,dc=com`). On success, WebSEAL creates a session and proxies the authorize request to the OIDC Provider with the `iv-user` header carrying the authenticated identity.
4. The OIDC Provider resolves the WebSEAL-authenticated identity into the `sub` claim, issues a one-time authorization code, and 302s the browser back to the Banking UI's `/callback?code=...&state=...`.
5. The Banking UI's `/callback` handler validates that the returned `state` matches the `pkce` cookie, then POSTs to the OIDC Provider's `/oauth2/token` endpoint over the in-cluster Kubernetes Service URL (`https://iviaop.verify-access.svc.cluster.local:8436`) — bypassing the WebSEAL ALB. The POST carries HTTP Basic auth (`agent-uc2:<client_secret>`) plus the `code` and `code_verifier`.
6. The OIDC Provider verifies the code, checks the PKCE proof against the original challenge, and runs the pre-token mapping rule (`pre_mappingrule_id: isvaop_pretoken`), which stamps `act.sub = agent-uc2` onto the access token. It returns an `access_token` carrying both `sub` and `act.sub`, plus an `id_token` carrying `sub` only.
7. The Banking UI stores the tokens in httpOnly cookies (`access_token`, `id_token`, optional `refresh_token`) and 302s the browser to `/dashboard`.
8. When the user asks a banking question, the UI's server-side proxy reads the **`access_token`** cookie and forwards it to the Banking Agent as a Bearer token. It must be the access token, not the `id_token` — IVIA's pre-token mapping rule stamps `act.sub = agent-uc2` onto the access token only. The `id_token` carries no `act` claim, so Vault would resolve no acting agent and deny the `database/creds` read.
9. The Banking Agent forwards the JWT unchanged to the MCP Server for each tool invocation — in the `Authorization: Bearer` header, and nowhere else. The tools take no `jwt` parameter: `get_accounts` accepts no arguments at all and `get_transactions` accepts only an optional `account_id`. If the acted-on token came from the tool arguments, the identity Vault saw would be whatever the caller typed into the payload and the header would constrain nothing.
10. The MCP Server presents the JWT **directly** to Vault as the `X-Vault-Token` header on a single `GET database/creds/uc2-personal-readonly` read — there is no `auth/jwt/login` round-trip and no intermediate Vault token. Vault's OAuth resource server validates the signature against IVIA's JWKS endpoint.
11. Vault resolves the human `sub` and the agent actor `act.sub = agent-uc2` (against the Agent Registry) and applies the On-Behalf-Of intersection `uc2-human-baseline ∩ uc2-agent-ceiling`.
12. In that same call Vault issues a JIT Postgres credential with a 15-minute TTL.
13. The MCP Server opens a Postgres connection, sets `app.current_user_sub` to the JWT's `sub` claim, and executes `SELECT` queries. PostgreSQL Row-Level Security filters results to the authenticated user's rows only.
14. The MCP Server revokes the lease as soon as the query returns — `POST /v1/sys/leases/revoke`, authenticated with the server's **own** Kubernetes-auth Vault token rather than the caller's, so the revoke still works when the user's JWT has already expired. Vault drops the Postgres role immediately. The 15-minute TTL remains only as a backstop for the case where the server dies mid-request.

The `sub` claim in the `access_token` (e.g. `oscar`) flows to:

1. The **Banking UI** — identifies the logged-in user for display.
2. The **Strands agent** — forwarded in the `Authorization: Bearer` header to the MCP server.
3. **Vault OAuth resource server** — the MCP server presents the JWT directly via `X-Vault-Token`; Vault resolves `sub` and the actor `act.sub = agent-uc2` and applies `uc2-human-baseline ∩ uc2-agent-ceiling`.
4. **PostgreSQL RLS** — the `app.current_user_sub` session variable is set from `sub`; the RLS policy filters `banking.accounts` rows to the authenticated user.

## Step 1 — Get the Banking UI URL

:::alert{header="Use an incognito / private browser window" type="info"}
Open the Banking UI in a fresh incognito / private window. Stale WebSEAL/IVIA session cookies from a previous login can prevent a clean sign-in, and this workshop has you log in as more than one user. Open a new incognito window for each user (Oscar, then Jaime) so each login starts from a clean session.
:::

At the end of `bash infrastructure/scripts/deploy-workshop.sh`, the script prints `NIP_FQDN_BANKING` — the banking-UI nip.io URL backed by a Let's Encrypt certificate served on the shared workshop ALB. Print the full HTTPS URL (read back from `infrastructure/.acme-state`) and open it in your browser:

```bash
echo "https://$(grep '^NIP_FQDN_BANKING=' infrastructure/.acme-state | cut -d= -f2)/"
```

:::alert{header="HTTPS with HTTP redirect — trusted Let's Encrypt cert" type="info"}
The Banking UI ALB listens on both HTTP (port 80) and HTTPS (port 443). HTTP requests are automatically redirected to HTTPS (ssl-redirect annotation). The certificate is a Let's Encrypt-issued cert bound to the nip.io FQDN and imported into ACM. You should see a lock icon in your browser address bar — the cert is trusted by every major OS/browser out of the box. If you see a "Your connection is not private" warning, this is a regression — re-run `bash infrastructure/scripts/deploy-workshop.sh` to re-issue the cert.
:::

## Step 2 — Sign in at the IVIA login page

When you open the Banking UI URL, the browser is immediately redirected to the IVIA WebSEAL Reverse Proxy login page. You will not see a Banking UI login form — the entire credential entry happens on IVIA.

Enter the pre-created test user credentials:

- **Username:** `oscar`
- **Password:** `WorkshopUser1!`

Click **Login**. WebSEAL performs an LDAP bind against OpenLDAP and, on success, redirects you back through `/isvaop/oauth2/authorize` to the Banking UI's `/callback?code=...` URL. The Banking UI exchanges the code for an access token and lands you on `/dashboard`.

:::alert{header="Where do these users come from?" type="info"}
This workshop uses OpenLDAP as the user registry, with two pre-provisioned users (Oscar and Jaime) created by the `verify_access` Terraform module. WebSEAL authenticates them via LDAP bind. The IVIA OIDC Provider then issues JWTs that the MCP Server uses to obtain user-scoped database credentials from Vault.
:::

## Step 3 — Inspect the Banking UI logs

View the Banking UI pod logs to confirm it is running and serving:

```bash
kubectl logs -n banking-app -l app=banking-ui --tail=30
```

Credentials never reach the Banking UI — they are entered on the WebSEAL login page and validated by WebSEAL via LDAP bind. The OAuth code-for-token exchange happens between the browser and IVIA/WebSEAL, so its detail is not in these UI logs; the authoritative record of the downstream credential issuance is the Vault audit log (queried via Athena in [Credential Revocation](../65-credential-revocation/)).

## Step 4 — Confirm personalized dashboard data

After login, the dashboard shows Oscar's accounts and transactions. Observe:

- The balance figures are specific to Oscar — RLS is filtering the `banking.accounts` table by `sub = 'oscar'`.
- The agent responds to natural-language queries about Oscar's financial data.

## Step 5 — Switch users: sign in as Jaime

To act as a different user, open a **new Incognito / Private browser window** and go to the Banking UI URL again. Sign in as:

- **Username:** `jaime`
- **Password:** `WorkshopUser1!`

:::alert{type="info" header="Why a second window here?"}
**Logout** fully signs you out: the Banking UI `/logout` handler clears its session cookies and then redirects to IVIA's `/pkmslogout`, which terminates the WebSEAL single sign-on session as well — so clicking Logout and signing back in as Jaime in the *same* window works and lands you on a fresh credential prompt. We open a **separate Incognito / Private window** here only so your Oscar session stays live in the first window and you can compare the two personas side-by-side.
:::

The dashboard now shows Jaime's accounts and transactions — not Oscar's. The `sub` claim changed, activating a different RLS filter in PostgreSQL.

## Step 6 — Confirm the tool contract has nowhere to put an identity

Steps 1 through 5 proved the login works. This step proves the claim that makes it worth anything: the token the MCP server acts on comes from the `Authorization` header and from nothing else.

Ask the MCP server to describe its own tools. `tools/list` needs no user — any non-empty bearer value gets past the auth gate, because listing tools touches neither Vault nor the database:

```bash
kubectl delete pod mcp-probe -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run mcp-probe --rm -i --quiet --restart=Never --image=curlimages/curl:8.11.1 -n banking-app \
  --command -- curl -s -X POST http://banking-mcp-svc:3001/mcp \
    -H 'Authorization: Bearer schema-probe' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | jq '.result.tools[] | {name, properties: .inputSchema.properties, required: .inputSchema.required}'
```

Expected output — `get_accounts` takes **no arguments at all**, `get_transactions` takes only an optional `account_id`, and neither requires anything:

```json
{
  "name": "get_accounts",
  "properties": {},
  "required": null
}
{
  "name": "get_transactions",
  "properties": {
    "account_id": {
      "type": "string",
      "description": "Optional account ID to filter transactions to a single account"
    }
  },
  "required": null
}
```

There is no `jwt` field. A caller cannot name the user it wants to be, because the contract has no field for it.

### Now prove it behaves that way

A schema is a promise. This request tests it: it puts a **JWT-shaped** token in the tool arguments and a string that is obviously **not a JWT** in the header. Whichever one the server acts on decides the error you get back.

```bash
kubectl delete pod mcp-probe -n banking-app --ignore-not-found --now >/dev/null 2>&1
kubectl run mcp-probe --rm -i --quiet --restart=Never --image=curlimages/curl:8.11.1 -n banking-app \
  --command -- curl -s -X POST http://banking-mcp-svc:3001/mcp \
    -H 'Authorization: Bearer not-a-jwt-at-all' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_accounts",
         "arguments":{"jwt":"eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJvc2NhciJ9.not-a-real-signature"}}}'
```

Expected output:

```json
{"result":{"content":[{"type":"text","text":"Error fetching accounts: Invalid JWT format: expected header.payload.signature"}],"isError":true},"jsonrpc":"2.0","id":1}
```

`not-a-jwt-at-all` is the header value, and `expected header.payload.signature` is the complaint about it. The server tried to use the **header** and never looked at the argument — even though the argument was the well-formed one.

:::alert{type="info" header="What the other answer would have meant"}
If the server had acted on the tool argument instead, that argument *is* JWT-shaped, so it would have travelled all the way to Vault and come back `Vault DB creds fetch failed [403]: {"errors":["permission denied"]}` — Vault rejecting an unsigned token. Same request, completely different error, and the header would have been decoration. Anything that could reach the MCP server would then be choosing the identity Vault saw, and the OBO intersection, the RLS predicate and the audit record would all faithfully enforce the *caller's* choice of user.
:::

## How the login is split between Banking UI and IVIA

IBM Verify Identity Access has two components in this deployment:

1. **IVIA OIDC Provider** (`iviaop` pod) — issues tokens, validates OAuth client credentials, runs the pre-token / post-token mapping rules. It does not render a login form.
2. **IVIA WebSEAL Reverse Proxy** (`iviawrprp1` pod) — sits in front of the OIDC Provider, renders the login form, performs LDAP bind against the user registry, and proxies authenticated traffic to the OIDC Provider with the user's identity attached as HTTP headers.

The Banking UI never displays a login form of its own. When an unauthenticated user lands on `/`, the SvelteKit server generates a PKCE verifier + challenge, sets a short-lived cookie, and 302s the browser to IVIA's `/oauth2/authorize` endpoint. The WebSEAL Reverse Proxy intercepts that request, serves its own HTML login form, validates the credentials against OpenLDAP, then proxies the (now authenticated) request to the OIDC Provider. The OIDC Provider issues a one-time authorization code and redirects the browser back to the Banking UI's `/callback` URL.

The Banking UI's `/callback` handler then exchanges the code for tokens server-to-server, directly against the OIDC Provider via the in-cluster Kubernetes Service URL — that exchange bypasses the WebSEAL Reverse Proxy entirely.

:::alert{header="Why PKCE for a server-side application?" type="info"}
PKCE protects against authorization code interception. Even though the Banking UI is a confidential client (it has a `client_secret`), PKCE is required by the IVIA `agent-uc2` client configuration (`require_pkce: true`). The PKCE pair (`code_verifier` + `code_challenge`) is generated server-side in `+page.server.ts`, persisted to a short-lived `pkce` httpOnly cookie, and verified by IVIA at the token exchange step.
:::

:::expand{header="Platform Track — IVIA OAuth client configuration"}

The IVIA `agent-uc2` client is provisioned by the `verify_access` Terraform module with these settings (declared in `modules/verify_access/iviaop-config/clients.yml.tftpl`):

| Setting | Value | Why |
|---|---|---|
| `client_id` | `agent-uc2` | Matches the OAuth resource server profile `audiences` (and the registered agent actor) |
| `client_secret` | `<generated>` | Confidential client — sent via HTTP Basic on the token exchange |
| `grant_types` | `authorization_code`, `refresh_token` | Authorization Code flow with optional refresh |
| `response_types` | `code` | Authorization Code response type |
| `require_pkce` | `true` | PKCE proof required at token exchange |
| `token_endpoint_auth_method` | `client_secret_basic` | HTTP Basic auth on `/oauth2/token` |
| `redirect_uris` | `http://<UI_ALB>/callback` | Patched post-deploy with the real Banking UI ALB hostname |
| `scopes` | `openid`, `profile`, `email` | JWT carries sub, email, name claims |

The authorize URL the browser is redirected to:

```
http://<IVIA_ALB>/isvaop/oauth2/authorize
  ?response_type=code
  &client_id=agent-uc2
  &redirect_uri=http://<UI_ALB>/callback
  &code_challenge=<S256 hash of code_verifier>
  &code_challenge_method=S256
  &state=<CSRF token>
  &scope=openid+profile+email
```

The token exchange the Banking UI server makes (in-cluster, bypasses the ALB):

```
POST https://iviaop.verify-access.svc.cluster.local:8436/oauth2/token
Authorization: Basic base64(agent-uc2:<client_secret>)
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=<one-time code>
&redirect_uri=http://<UI_ALB>/callback
&code_verifier=<original PKCE verifier>
```

The `client_secret` is injected into the Banking UI pod from the `banking-ui-oidc` **Kubernetes Secret** — never a ConfigMap. Each OIDC client registered with the provider (`agent-uc1`, `agent-uc2`, `agent-uc3`, `uc3-actor`) is generated its own distinct secret at deploy time by the `verify_access` Terraform module, so holding one client's credential does not let you authenticate as another.

Confirm both properties on the running cluster:

```bash
kubectl get configmap -n banking-app banking-ui-config -o yaml | grep -c CLIENT_SECRET; kubectl get secret -n banking-app banking-ui-oidc -o jsonpath='{.data.IVIA_CLIENT_SECRET}' | wc -c
```

The first number is `0` — no credential in the ConfigMap. The second is non-zero — the secret is present, base64-encoded, in the Secret.

How the Banking UI maps to the SvelteKit file structure:

```
src/routes/
  +page.svelte          — Minimal fallback (server always 302s first)
  +page.server.ts       — Load: redirects authenticated users to /dashboard,
                          generates PKCE and 302s everyone else to IVIA
  callback/
    +page.server.ts     — Validates state, posts to /oauth2/token, sets cookies
  dashboard/
    +page.svelte        — Personalized banking dashboard
  logout/
    +server.ts          — Clears session cookies, redirects to IVIA /pkmslogout
src/lib/
  auth.ts               — Server-side PKCE helpers: generatePkce,
                          buildAuthorizeUrl, exchangeCodeForTokens
```
:::

:::expand{header="Agent Developer Track — JWT claims and how the agent uses them"}

The Banking Agent receives the user's JWT in the `Authorization: Bearer <token>` header of every API call from the Banking UI. The agent does **not** validate the JWT signature — that is Vault's responsibility. The agent treats the JWT as an opaque credential and forwards it to the MCP Server.

The MCP Server presents the OAuth JWT **directly** to Vault as the `X-Vault-Token` header on a single `database/creds` read — there is no `auth/jwt/login` round-trip and no intermediate Vault token:

```typescript
// vault-client.ts
export async function getDbCreds(
  oauthJwt: string,
  role: string = 'uc2-personal-readonly'
): Promise<DbCredentials> {
  const url = `${VAULT_ADDR}/v1/database/creds/${role}`;

  const res = await fetch(url, {
    method: 'GET',
    headers: { 'X-Vault-Token': oauthJwt },   // the IVIA OAuth JWT, presented directly
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Vault DB creds fetch failed [${res.status}]: ${body}`);
  }

  const data = (await res.json()) as {
    data?: { username?: string; password?: string };
    lease_id?: string;
    lease_duration?: number;
  };
  // ... returns { username, password, leaseId, leaseDuration }
}
```

Vault's OAuth resource server validates the JWT against IVIA's JWKS endpoint (the signing CA pinned in the `ivia` profile), resolves the human `sub` and the agent actor `act.sub = agent-uc2` (against the Agent Registry), and applies the On-Behalf-Of intersection `uc2-human-baseline ∩ uc2-agent-ceiling` — all in that one `database/creds` read.

The `sub` claim value (e.g., `oscar`) is also passed directly to the Postgres session:

```typescript
// mcp-server tools handler
await client.query("SET app.current_user_sub = $1", [sub]);
const accounts = await client.query(
  "SELECT * FROM banking.accounts"  // RLS filters by app.current_user_sub
);
```

This is the complete chain: `sub` in JWT → presented as `X-Vault-Token` on the `database/creds` read → Postgres session variable → RLS predicate. Each link is visible in application code — no magic.
:::
