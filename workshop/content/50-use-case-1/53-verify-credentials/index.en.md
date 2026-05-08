---
title: 'Verify Credentials and Enforcement'
weight: 53
---

## Overview

In this module you send a query to the UC1 agent, observe just-in-time credential issuance in the Vault audit log, run the ENFC-01 enforcement test (proving UC1 cannot access UC3 credentials), and execute `verify-uc1.sh` to validate all end-to-end criteria.

## Step 1 — Port-forward to the agent service

```bash
kubectl port-forward -n uc1 svc/uc1-agent-svc 8080:80
```

Leave this running in a separate terminal. The agent is now reachable at `http://localhost:8080`.

## Step 2 — Send a query

```bash
curl -s http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "What security controls are available in the workshop?"}' \
  | jq .
```

The response includes a `credential_metadata` field that surfaces Vault authentication details:

```json
{
  "answer": "The workshop demonstrates five security controls...",
  "credential_metadata": {
    "vault_authenticated": true,
    "vault_role": "uc1",
    "db_lease_id": "database/creds/uc1-readonly/AbCd1234...",
    "db_lease_ttl": 900,
    "sts_lease_id": "aws/sts/bedrock-reader/XyZw5678..."
  }
}
```

Note the `db_lease_ttl` value of `900` seconds (15 minutes). The `db_lease_id` and `sts_lease_id` fields are the Vault lease identifiers you can use to look up revocation events.

## Step 3 — Observe credential issuance in the Vault audit log

```bash
kubectl logs -n vault vault-0 --tail=50 \
  | grep '"type":"response"' \
  | jq 'select(.request.path == "database/creds/uc1-readonly")' \
  | jq '{time: .time, path: .request.path, auth_display_name: .auth.display_name, ttl: .response.data.lease_duration}'
```

Expected output for each query you sent:

```json
{
  "time": "2026-05-08T22:55:12.123Z",
  "path": "database/creds/uc1-readonly",
  "auth_display_name": "kubernetes/uc1",
  "ttl": 900
}
```

The `auth.display_name` field shows `kubernetes/uc1` — the Vault mount path and role name. This entry is the first link in the audit correlation chain: the same `lease_id` appears in the Postgres `pg_audit` log (CloudWatch) and, in Phase 6, in the Athena JOIN query that correlates agent identity to data access.

Also verify the STS credential issuance:

```bash
kubectl logs -n vault vault-0 --tail=50 \
  | grep '"type":"response"' \
  | jq 'select(.request.path | startswith("aws/sts/bedrock-reader"))' \
  | jq '{time: .time, path: .request.path, auth_display_name: .auth.display_name}'
```

## Step 4 — ENFC-01 enforcement test — attempt UC3 credential from UC1 identity

The `uc1-readonly` Vault policy does not include a path for `database/creds/uc3-refund-writer`. Verify this directly:

```bash
vault policy read uc1-readonly | grep uc3
```

Expected output: no output (the pattern does not match — there is no UC3 path in the policy).

To see the policy-text-absence in context:

```bash
vault policy read uc1-readonly
```

Confirm that `uc3-refund-writer` does not appear in any path. This policy-level absence is the enforcement proof for ENFC-01 at the credential layer.

If you want to confirm Vault returns a 403 at runtime, exec into the pod and attempt the fetch directly:

```bash
kubectl exec -n uc1 deploy/uc1-agent -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}" \
    -H "X-Vault-Token: $(cat /tmp/.vault-token 2>/dev/null || echo invalid)" \
    "${VAULT_ADDR}/v1/database/creds/uc3-refund-writer"'
```

Expected output: `403`

## Step 5 — Run verify-uc1.sh

The `verify-uc1.sh` script checks all end-to-end success criteria for Use Case 1:

```bash
bash infrastructure/scripts/verify-uc1.sh
```

The script runs the following checks and prints a pass/fail summary:

| Check | What It Validates |
|---|---|
| UC1 pod Running | `kubectl get pods -n uc1` shows `1/1 Running` |
| ServiceAccount bound | `uc1-retriever-sa` exists in the `uc1` namespace |
| Vault role exists | `vault read auth/kubernetes/role/uc1` returns `bound_service_account_names=[uc1-retriever-sa]` |
| DB creds issuable | `vault read database/creds/uc1-readonly` returns a username + password |
| STS creds issuable | `vault read aws/sts/bedrock-reader` returns access_key + security_token |
| KB retrieve succeeds | Agent responds to a test query with a non-empty `answer` field |
| ENFC-01 enforced | UC1 token cannot access `database/creds/uc3-refund-writer` — Vault returns 403 |
| Audit log entry present | Vault audit log contains a `database/creds/uc1-readonly` response entry |

Expected summary output:

```
[PASS] UC1 pod Running (1/1)
[PASS] ServiceAccount uc1-retriever-sa present in namespace uc1
[PASS] Vault Kubernetes role uc1 bound to uc1-retriever-sa
[PASS] Vault DB creds issuable for uc1-readonly (TTL=900s)
[PASS] Vault STS creds issuable for bedrock-reader
[PASS] Agent query returned non-empty answer
[PASS] ENFC-01: UC1 token cannot access uc3-refund-writer (403)
[PASS] Vault audit log contains uc1-readonly issuance entry

8 check(s) passed, 0 failed.
```

If any check fails, the script prints a `Fix hint:` line indicating the remediation step.

:::expand{header="Agent Developer Track — Query flow through app.py, agent.py, and vault_client.py"}

When you POST to `/query`, the following call chain executes:

```
FastAPI (app.py)
  └── POST /query
        └── agent_handler(query)            ← app.py
              └── VaultClient.get_db_creds() ← vault_client.py
              │     └── client.secrets.database.generate_credentials("uc1-readonly")
              │           └── Vault API: GET /v1/database/creds/uc1-readonly
              │                 └── Returns: username, password, lease_id, lease_duration=900
              │
              └── VaultClient.get_sts_creds() ← vault_client.py
              │     └── client.secrets.aws.generate_credentials(name="bedrock-reader")
              │           └── Vault API: GET /v1/aws/sts/bedrock-reader
              │                 └── Returns: access_key, secret_key, security_token
              │
              └── build_agent(sts_creds)      ← agent.py
              │     └── boto3.Session(aws_access_key_id=..., aws_session_token=...)
              │           └── BedrockModel(model_id="us.amazon.nova-pro-v1:0", boto_session=session)
              │
              └── agent.invoke_with_tools(query) ← agent.py (Strands)
                    └── retrieve_from_kb(session, KB_ID, query)
                          └── bedrock-agent-runtime.retrieve(knowledgeBaseId=KB_ID, ...)
```

The Postgres connection (via `psycopg2.connect(host=RDS_ADDR, user=pg_user, password=pg_pass)`) opens a fresh connection on each request using the JIT credential. When the 15-minute TTL expires, Vault revokes the Postgres role and any open connection using those credentials will receive an authentication error on its next query — a natural forcing function for connection pool refresh.

The `credential_metadata` in the response is assembled by the agent after each credential fetch, surfacing the `vault_role`, `db_lease_id`, and TTL values for the attendee exercises in Steps 2 and 3 above.
:::

:::expand{header="Platform/Security Track — Vault lease lifecycle: issuance, TTL countdown, auto-revocation"}

The lifecycle of a JIT Postgres credential issued at Step 2 is:

```
T+0s   Agent calls /v1/database/creds/uc1-readonly
       Vault generates: username="v-kubernetes-uc1-readonly-AbCd1234", password="<random>"
       Vault executes in Postgres:
         CREATE ROLE "v-kubernetes-uc1-readonly-AbCd1234"
           WITH LOGIN PASSWORD '<password>'
           VALID UNTIL '<now + 15m>'
           IN ROLE uc1_reader;
       Vault stores lease metadata: lease_id, expiry = now + 900s

T+900s (TTL expires)
       Vault lease expiry fires — revocation job runs
       Vault executes in Postgres:
         DROP ROLE IF EXISTS "v-kubernetes-uc1-readonly-AbCd1234";
       Vault audit log records revocation event
       Any open Postgres connection using these credentials fails at next query
```

You can observe the active lease immediately after the query:

```bash
vault lease list database/creds/uc1-readonly
```

After 15 minutes, the same command returns an empty list — the lease is gone and the Postgres role no longer exists.

The `uc1_reader` Postgres role (a permanent role created by Vault's dynamic secrets engine setup) provides the `IN ROLE` grant that gives the ephemeral role read-only access to the `workshop` schema. This permanent role has no LOGIN privilege itself — it is a grant vehicle only.

Why does this matter for OBJ-2? If the agent pod is compromised at `T+800s`, the attacker has at most 100 seconds of valid Postgres access before the credential self-destructs. There is no long-lived password to rotate, no secrets manager entry to update, no rotation lambda to invoke.
:::

---

:::alert{header="What Would Have Failed" type="warning"}
**Without workload identity (OBJ-1):** If the agent pod had no dedicated ServiceAccount or used the `default` ServiceAccount, Vault's Kubernetes auth role binding (`bound_service_account_names = ["uc1-retriever-sa"]`) would reject the JWT. The pod would receive a Vault 403 at startup and the agent would be unable to fetch any credentials. Workload identity is the trust anchor — without it there is no credential issuance.

**With shared credentials (OBJ-2 violation):** If all agents shared a single long-lived database password (stored in a Secret or environment variable), a compromised UC1 agent could read and write to any table, and the password would remain valid indefinitely unless manually rotated. JIT credentials with a 15-minute TTL limit the blast radius to one query window — after which the credential self-destructs and Vault records the revocation.

**Without audit (OBJ-5 violation):** If Vault audit logging were disabled, there would be no record of which agent identity requested which credential at what time. The Vault audit log entry you observed in Step 3 — with `auth.display_name = "kubernetes/uc1"` and the `lease_id` — is the first link in the audit correlation chain that Phase 6 (Use Case 3) completes end-to-end. Without it, a security incident investigation would have no starting point for attributing data access to a specific workload identity.
:::
