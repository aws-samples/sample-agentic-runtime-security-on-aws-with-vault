---
title: 'Verify Credentials and Enforcement'
weight: 52
---

## Overview

Query the Use Case 1 agent, watch Vault issue just-in-time credentials, prove the agent **cannot** reach Use Case 3 credentials (ENFC-01), and run `verify-uc1.sh` to confirm every success criterion.

## Step 1 — Ask the agent (no sign-in)

The agent is exposed through a public, read-only chat page. At the end of `bash infrastructure/scripts/configure-workshop.sh` the script prints `NIP_FQDN_BANKING` (the banking-UI nip.io URL backed by a Let's Encrypt cert). Use that URL — or read it back from `infrastructure/.acme-state`:

```bash
grep '^NIP_FQDN_BANKING=' infrastructure/.acme-state
```

Open `https://<NIP_FQDN_BANKING>/ask` in your browser. You should see a lock icon in your browser address bar (the page is served with a Let's Encrypt-issued certificate the OS trusts out of the box). If you see a "Your connection is not private" warning, this is a regression — re-run `bash infrastructure/scripts/configure-workshop.sh` to re-issue the cert. No login is required — the page is workload-identity only. Ask a knowledge-base question, for example:

> Summarize the employee PTO policy, including accrual by tenure.

You get an answer grounded in the Knowledge Base corpus (PTO accrual: 15 days at 0–2 years, 20 at 2–5, 25 at 5+). The agent reached that answer using credentials it did not have until the moment you asked.

## Step 2 — Inspect the credential metadata (CLI)

To see the Vault authentication behind the answer, port-forward and call `/query` directly:

```bash
kubectl port-forward -n uc1 svc/uc1-agent-svc 8080:80
```

In a second terminal:

```bash
curl -s http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Summarize the employee PTO policy."}' \
  | jq '{answer: .answer, credential_metadata: .credential_metadata}'
```

The response surfaces the Vault authentication state:

```json
{
  "answer": "Paid time off accrues monthly based on tenure ...",
  "credential_metadata": {
    "vault_authenticated": true,
    "vault_role": "uc1"
  }
}
```

`vault_authenticated: true` with `vault_role: uc1` confirms the pod authenticated to Vault with its ServiceAccount identity — not a static key.

## Step 3 — Observe credential issuance in the Vault audit log

Each `/query` triggers a fresh Vault credential issuance. Read the audit log for the database credential event:

```bash
kubectl logs -n vault vault-0 --tail=100 \
  | grep '"type":"response"' \
  | jq 'select(.request.path == "database/creds/uc1-readonly")
        | {time: .time, path: .request.path,
           display_name: .auth.display_name,
           ttl: .response.data.lease_duration}' \
  | tail -1
```

Expected:

```json
{
  "time": "2026-05-26T22:14:58Z",
  "path": "database/creds/uc1-readonly",
  "display_name": "kubernetes-uc1-uc1-retriever-sa",
  "ttl": 900
}
```

`display_name` is `kubernetes-uc1-uc1-retriever-sa` — the Vault Kubernetes mount, the role, and the ServiceAccount that authenticated. This entry is the first link in the audit-correlation chain that Use Case 3 completes end-to-end. The `ttl` of `900` seconds is the 15-minute database credential lifetime.

## Step 4 — ENFC-01 enforcement test (the thing that must NOT happen)

Use Case 1 is read-only and must never obtain Use Case 3's refund-writer database credentials. Have the agent attempt it **with its own Vault identity** — Vault must refuse:

```bash
kubectl exec -n uc1 deploy/uc1-agent -- python3 -c '
from app.agent import _vault
_vault.login()
try:
    _vault.client.read("database/creds/uc3-refund-writer")
    print("BREACH — UC1 obtained UC3 write credentials")
except Exception as e:
    print("DENIED (expected):", type(e).__name__)
'
```

Expected output:

```
DENIED (expected): Forbidden
```

The `403 Forbidden` is the passing result — the UC1 token can mint its own `database/creds/uc1-readonly` but is denied `database/creds/uc3-refund-writer`, because that path is absent from the `uc1-readonly` policy (you read that policy on the previous page).

## Step 5 — Run verify-uc1.sh

```bash
bash infrastructure/scripts/verify-uc1.sh
```

The script runs nine checks and prints a pass/fail summary:

| Check | What it validates |
|---|---|
| Pod Running | `uc1-agent` pod is `1/1 Running` in the `uc1` namespace |
| ServiceAccount | `uc1-retriever-sa` exists |
| Vault role | role `uc1` is bound to `uc1-retriever-sa` |
| JIT DB creds | `database/creds/uc1-readonly` issues a username + password |
| JIT STS creds | `aws/sts/bedrock-reader` issues an access key + session token |
| Agent /health | the agent reports `healthy` |
| ENFC-01 | the `uc1-readonly` policy does not grant the UC3 refund path |
| Audit device | a Vault audit device is enabled |
| /query end-to-end | a real query returns a KB-grounded answer (not "couldn't find it") |

Expected summary:

```
✓ PASS UC1 agent pod Running (1 pod(s) in uc1)
✓ PASS UC1 ServiceAccount uc1-retriever-sa exists
✓ PASS Vault role uc1 bound to uc1-retriever-sa
✓ PASS JIT DB creds issuance: username=v-kubernet-uc1-read-...
✓ PASS JIT STS creds issuance: access_key=ASIA...
✓ PASS Agent /health endpoint: healthy
✓ PASS ENFC-01: uc1-readonly policy does not grant UC3 (uc3-refund-writer) path access
✓ PASS Vault audit device: enabled (1 device(s))
✓ PASS Agent /query end-to-end: KB retrieve + Nova Pro answer returned

 ✓ 9 check(s) passed
```

If a check fails, the script prints a copy-paste `Fix hint`. The `/query end-to-end` check fails (not falsely passes) if the Knowledge Base is empty — its fix hint points to `./sync-bedrock-kb.sh`.

:::expand{header="Platform/Security Track — Vault lease lifecycle: issuance, TTL, auto-revocation"}

A JIT Postgres credential issued at Step 2 lives exactly 15 minutes:

```
T+0s    Agent calls database/creds/uc1-readonly
        Vault runs in Postgres: CREATE ROLE "v-kubernet-uc1-read-..."
          WITH LOGIN PASSWORD '<random>' VALID UNTIL '<now + 15m>';
          GRANT SELECT ON ALL TABLES IN SCHEMA public TO "...";
        Vault stores the lease: expiry = now + 900s

T+900s  Lease expiry fires — Vault runs: DROP ROLE IF EXISTS "v-kubernet-uc1-read-...";
        Any open connection using that credential fails on its next query
```

Observe the active lease right after a query, then watch it disappear after 15 minutes:

```bash
vault lease list database/creds/uc1-readonly
```

Why this matters for OBJ-2: if the pod is compromised at T+800s, the attacker has at most 100 seconds of Postgres access before the credential self-destructs — no long-lived password to rotate, no rotation job to run.
:::

:::expand{header="Why this design — what would have failed"}

- **No workload identity (OBJ-1):** with the `default` ServiceAccount, Vault's role binding (`bound_service_account_names = [uc1-retriever-sa]`) rejects the JWT — the pod gets a 403 at startup and can fetch nothing. The SA JWT *is* the credential.
- **Shared static credentials (OBJ-2):** a single long-lived DB password would stay valid indefinitely and grant every agent the same access. The 15-minute JIT credential limits the blast radius to one query window.
- **No audit (OBJ-5):** without the Vault audit log entry from Step 3, there is no record tying a credential to an identity — an incident investigation would have no starting point.
:::
