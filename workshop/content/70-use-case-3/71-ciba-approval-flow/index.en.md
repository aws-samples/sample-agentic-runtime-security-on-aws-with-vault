---
title: 'CIBA Out-of-Band Approval'
weight: 71
---

## How CIBA Works

CIBA (OpenID Connect Client-Initiated Backchannel Authentication) lets an automated agent request user approval without controlling the browser session. The agent initiates the flow on the backchannel; the user approves out-of-band on a separate device — here, an **IBM Verify mobile push** that requires a physical tap on the enrolled phone.

## CIBA Mobile-Push Approval Flow

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
    participant Agent as Use Case 3 Agent
    participant OP as OIDC Provider<br/>(ClusterIP)
    participant RT as AAC Runtime<br/>(MMFA + SCIM)
    participant Phone as IBM Verify App<br/>(user's device)

    Agent->>OP: POST /oauth2/ciba<br/>(login_hint, binding_message, authorization_details)
    OP->>OP: notifyuser rule →<br/>ExternalAuthenticatorWithCheckStatusEndpoint(/api/ciba/status)
    OP-->>Agent: auth_req_id
    Agent->>RT: Fire MMFA push<br/>(authsvc mmfa_initiate_simple_login, username)
    RT->>Phone: Push "Approve your OscarVault request"
    Note over Phone: User taps Approve<br/>(physical device + biometric)
    Phone->>RT: Approval recorded → SCIM MMFA txn = SUCCESS
    loop Agent polls /token every 5s (up to 120s)
        Agent->>OP: POST /oauth2/token<br/>(grant_type=ciba, auth_req_id)
        OP->>Agent: checkstatus rule: PUT /api/ciba/status<br/>(CIBA bearer)
        Agent->>RT: Read user's OWN SCIM MMFA txn<br/>(exact fired transactionId)
        RT-->>Agent: SUCCESS / pending
        Agent-->>OP: status approved (uid jaime) — or pending
    end
    OP-->>Agent: access_token (subject_token, sub=jaime)
```

**Step-by-step:**

1. The agent POSTs `/oauth2/ciba` (bc-authorize) directly to the OIDC Provider ClusterIP with `login_hint=<user_sub>`, `binding_message=<request_id>`, and the refund `authorization_details`. This is machine-to-machine — it bypasses the WRP. IVIA returns an `auth_req_id`.
2. IVIA runs the `notifyuser` mapping rule. In the mobile-push design it does **not** serve a browser consent page — it wires CIBA completion to a server-polled check-status endpoint on the agent via `ExternalAuthenticatorWithCheckStatusEndpoint(<uc3-agent>/api/ciba/status, bearer)`.
3. The agent fires the MMFA push itself, right after bc-authorize, to the authenticated user's IBM Verify device (AAC runtime authsvc policy `mmfa_initiate_simple_login`, message "Approve your OscarVault request"). Identity comes from the authenticated session — never an LLM parameter. The agent records `auth_req_id → {username, transaction_id}`.
4. The user taps **Approve** on the IBM Verify app (physical device, biometric). The MMFA transaction resolves to `SUCCESS` in that user's SCIM record.
5. The agent polls `/oauth2/token` (`grant_type=urn:openid:params:grant-type:ciba`, `auth_req_id`) every 5 seconds for up to 120 seconds. On **each** poll IVIA runs the `checkstatus` rule, which PUTs the agent's `/api/ciba/status` with the CIBA bearer. The agent reads the user's **own** SCIM MMFA transaction for the **exact** push it fired and returns `approved` / `denied` / `pending` — a stale or unrelated SUCCESS cannot complete the flow.
6. When the agent returns `approved`, `checkstatus` calls `ciba.success({sub})` and the `/token` poll returns the access token (`subject_token`) carrying the user's identity. (Deny → `ciba.failed()`; otherwise `ciba.pending()` and the agent keeps polling.)

:::alert{header="Why the approval is unforgeable" type="info"}
Two independent facts must both hold before the refund proceeds: the user physically taps **Approve** on their enrolled device, AND the agent confirms that the **exact** MMFA transaction it fired (matched by `transactionId`, never "any SUCCESS for the user") resolved to `SUCCESS` in that user's own SCIM record. The CIBA bearer is replayed to the check-status endpoint as a per-request shared secret — defense-in-depth on top of the SCIM gate. The backchannel (bc-authorize and token poll) is machine-to-machine and never touches the WRP.
:::

## RFC 8693 Token Exchange

The CIBA access token proves the user approved, but it does not prove *which agent* is acting. Token Exchange (RFC 8693) produces a delegated JWT that carries both.

The Use Case 3 agent presents only the user's token, authenticated as a **separate** OAuth client (`uc3-actor`) via HTTP Basic — IVIA rejects a client exchanging its own token (`FBTAQ5207E`), so no `actor_token` is sent:
- `subject_token` = the CIBA-issued user access token (proves user identity + consent)

IVIA returns a delegated JWT containing:
- `sub` = the approving user (the human who completed the CIBA consent — e.g. `jaime`)
- `may_act.sub` = `uc3-actor` — injected server-side by the `isvaop_pretoken` mapping rule on the token-exchange grant (proves delegation)
- `authorization_details` = `[{"type": "refund_approval"}]` — the RAR **type**, also stamped by `isvaop_pretoken`

The delegated JWT is what the agent presents to Vault. Vault's `bound_claims` enforce that **both** `may_act.sub` (= `uc3-actor`) and `authorization_details[0].type` (= `refund_approval`) match before issuing any DB credentials.

:::alert{header="The approved amount is NOT a token claim — and that is correct" type="info"}
The amount and currency the user approved at consent time (e.g. `$88.30 USD`) are **not** carried on the exchanged JWT. IBM Verify (ISVAOP 25.10) exposes the consent-time `authorization_details` only as a context attribute on the request that *carries* it (`bc-authorize`) and as a token-*response* field — it is **not** available to any mapping rule at the CIBA mint or the token-exchange stage, so it cannot be stamped as a Vault-validated claim. (Confirmed against the live system and IBM's `tasks-rar` / `js_ciba_mapping_rule` docs, 2026-05-29.) Vault `bound_claims` are string/glob matches and could not numerically enforce an amount in any case. The amount is instead **consent-bound by three-plane audit correlation on `request_id`** — covered on the [Three-Plane Audit Correlation](../74-three-plane-audit/) page. So the CIBA flow still fully works: the user's out-of-band approval is what produced the `subject_token`, and the forensic row proves the approved amount equals the amount written.
:::

:::expand{header="Platform Track — IVIA CIBA Configuration"}
The IVIA CIBA client (`agent-uc3`) is configured in the `verify_access` Terraform module:

- `grant_types`: `["urn:openid:params:grant-type:ciba", "urn:ietf:params:oauth:grant-type:token-exchange"]`
- `token_endpoint_auth_method`: `client_secret_basic`

The provider binds two CIBA mapping rules (`provider.yml`: `notifyuser_mappingrule_id: notifyuser`, `checkstatus_mappingrule_id: checkstatus`) defined in `infrastructure/modules/verify_access/iviaop-config/rules.yaml`:

- **`notifyuser`** runs once during bc-authorize. It sets `ExternalAuthenticatorWithCheckStatusEndpoint(statusUrl, bearer)` where `statusUrl = http://uc3-agent-svc.banking-app.svc.cluster.local:8080/api/ciba/status?auth_req_id=<id>`. This replaces the older `InternalAuthenticator` browser-consent page — there is no browser consent in the mobile-push design.
- **`checkstatus`** runs on every `/token` poll. It `httpPut`s the agent's check-status endpoint with the CIBA bearer and maps the JSON response to `ciba.success({sub})` / `ciba.failed()` / `ciba.pending()`.

The push itself is fired by the agent against the AAC runtime authsvc policy `mmfa_initiate_simple_login` (`base_layer.yaml.tftpl`), which initiates an MMFA user-presence transaction with the message "Approve your OscarVault request".
:::

:::expand{header="Agent Dev Track — Push, Poll, and Check-Status Code"}
The Use Case 3 agent implements the mobile-push flow in `applications/uc3-agent/app/agent.py` and `mmfa.py`:

```python
# 1. Initiate CIBA (direct to OIDC Provider ClusterIP — bypasses WRP)
resp = httpx.post(f"{IVIA_BASE_URL}/oauth2/ciba", data={
    "login_hint": authenticated_sub,        # from the verified session, never the LLM
    "binding_message": request_id,
    "authorization_details": json.dumps(rar),
    "scope": "openid",
}, auth=(CLIENT_ID, CLIENT_SECRET), verify=IVIA_CA_BUNDLE)
auth_req_id = resp.json()["auth_req_id"]

# 2. The agent fires the MMFA push itself, then records the transaction
txn_id = mmfa.fire_push(authenticated_sub)          # AAC authsvc mmfa_initiate_simple_login
ciba_store.put_txn(auth_req_id, authenticated_sub, txn_id)

# 3. Poll /token; IVIA's checkstatus rule calls back into /api/ciba/status,
#    which reads the user's OWN SCIM transaction for THIS txn_id.
for _ in range(24):                                  # 5s interval, 120s timeout
    time.sleep(5)
    tr = httpx.post(f"{IVIA_BASE_URL}/oauth2/token", data={
        "grant_type": "urn:openid:params:grant-type:ciba",
        "auth_req_id": auth_req_id,
    }, auth=(CLIENT_ID, CLIENT_SECRET), verify=IVIA_CA_BUNDLE)
    if tr.status_code == 200:
        subject_token = tr.json()["access_token"]
        break
```

The check-status endpoint the agent serves (`main.py`):

```python
@app.put("/api/ciba/status")
async def ciba_status(request, auth_req_id: str):
    entry = ciba_store.get_txn(auth_req_id)          # {username, txn_id}
    status = mmfa.read_txn_status(entry["username"], entry["txn_id"])  # SCIM read
    if status == "approved":
        return {"status": "approved", "uid": entry["username"]}
    return {"status": status}                         # denied | pending
```
:::

## Verification

Check the CIBA mobile-push + token exchange path is working:

```bash
# Confirm the Use Case 3 agent pod is running
kubectl get pods -n banking-app -l app=uc3-agent
```

```bash
# Watch the mobile-push flow in the agent logs (push fired, then check-status polls)
kubectl logs -n banking-app -l app=uc3-agent --tail=50 | grep -E 'mmfa_push_fired|ciba_status_polled'
```

```bash
# Confirm the IVIA CIBA endpoint is reachable from the vault pod (direct ClusterIP path)
kubectl exec -n vault vault-0 -- sh -c \
  "wget -q -O - --no-check-certificate \
  'https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration'" \
  | jq '.backchannel_authentication_endpoint'
```
