---
title: 'CIBA Out-of-Band Approval'
weight: 71
---

## How CIBA Works

CIBA (OpenID Connect Client-Initiated Backchannel Authentication) lets an automated agent request user approval without controlling the browser session. The agent initiates the flow on the backchannel; the user approves on a separate device.

**Step-by-step:**

1. Agent POSTs to `/bc-authorize` with `login_hint=<user_sub>` and `binding_message=<request_id>` — the `binding_message` is what the user sees in the approval notification.
2. IVIA returns an `auth_req_id`. The agent stores this and begins polling.
3. IVIA sends a push notification (or displays a consent screen) to the user. The user sees the `binding_message` and verifies it matches their expected action before approving.
4. Agent polls `/token` with `grant_type=urn:openid:params:grant-type:ciba` and `auth_req_id` at 5-second intervals (up to 120 seconds).
5. After approval, IVIA returns an access token (`subject_token`) with the user's identity claims.

## RFC 8693 Token Exchange

The CIBA access token proves the user approved, but it does not prove *which agent* is acting. Token Exchange (RFC 8693) produces a delegated JWT that carries both.

The UC3 agent exchanges:
- `subject_token` = the CIBA-issued user access token (proves user identity)
- `actor_token` = the agent's own Kubernetes service account JWT (proves agent identity)

IVIA returns a delegated JWT containing:
- `sub` = the user (`oscar`)
- `may_act.sub` = the agent's service account identity (`service-account:agent-uc3`)
- `authorization_details` = `[{"type": "refund_approval", "amount": 50.00, "currency": "USD"}]`

The delegated JWT is what the agent presents to Vault. Vault's `bound_claims` enforce that **both** `may_act.sub` and `authorization_details[0].type` match before issuing any DB credentials.

:::expand{header="Platform Track — IVIA CIBA Configuration"}
The IVIA CIBA client (`agent-uc3`) is configured in the `isva_config` Terraform module:

- `grant_types`: `["urn:openid:params:grant-type:ciba", "urn:ietf:params:oauth:grant-type:token-exchange"]`
- `backchannel_user_code_parameter_supported`: `true` (binding_message enforcement)
- `token_endpoint_auth_method`: `client_secret_post`

The IVIA token exchange endpoint at `/token` accepts `actor_token_type=urn:ietf:params:oauth:token-type:jwt` (Kubernetes SA JWT) and `subject_token_type=urn:ietf:params:oauth:token-type:access_token`.
:::

:::expand{header="Agent Dev Track — Polling Loop and Token Exchange Code"}
The UC3 agent implements CIBA polling in `applications/uc3-agent/app/auth.py`:

```python
# Initiate CIBA
resp = requests.post(f"{IVIA_BASE}/bc-authorize", data={
    "client_id": CLIENT_ID,
    "client_secret": CLIENT_SECRET,
    "login_hint": user_sub,
    "binding_message": request_id,  # propagated as traceparent
    "scope": "openid",
})
auth_req_id = resp.json()["auth_req_id"]

# Poll until approved (5s interval, 120s timeout)
for _ in range(24):
    time.sleep(5)
    token_resp = requests.post(f"{IVIA_BASE}/token", data={
        "grant_type": "urn:openid:params:grant-type:ciba",
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "auth_req_id": auth_req_id,
    })
    if token_resp.status_code == 200:
        subject_token = token_resp.json()["access_token"]
        break
```
:::

## Verification

Check CIBA + token exchange is working:

```bash
# Confirm UC3 agent pod is running
kubectl get pods -n banking-app -l app=uc3-agent

# Tail agent logs to see CIBA polling output
kubectl logs -n banking-app -l app=uc3-agent --tail=50

# Confirm IVIA CIBA endpoint is reachable from vault pod
kubectl exec -n vault vault-0 -- sh -c \
  "wget -q -O - --no-check-certificate \
  'https://isvaop.verify-access.svc.cluster.local:8436/.well-known/openid-configuration'" \
  | jq '.backchannel_authentication_endpoint'
```
