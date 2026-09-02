---
title: 'Vault Enforces the RAR Ceiling'
weight: 72
---

## How Vault Enforces Delegation Natively

Use Case 3 is an **on-behalf-of** flow: the agent acts for a human who approved a specific refund out-of-band (the CIBA flow on the [previous page](../71-ciba-approval-flow/)). Vault Enterprise's **OAuth resource server** enforces that delegation directly — no hand-rolled auth backend in between.

When the delegated IVIA OAuth JWT is presented to Vault via `X-Vault-Token`, Vault validates it against the resource server profile and resolves **two** identities from its claims: the human subject (`sub = jaime`) and the agent actor (`act.sub = uc3-actor`). It then evaluates **three enforcing layers**:

```
Delegated OAuth JWT (X-Vault-Token)
   sub = jaime                 (the human who approved)
   act.sub = uc3-actor         (the agent acting on their behalf)
   authorization_details = [ { "type": "vault:path_access",
                               "path": "database/creds/uc3-refund-writer",
                               "capabilities": ["read"] } ]   (per-request RAR — MANDATORY for UC3)
  →  Layer 1  human baseline    (uc3-refund-writer policy set — what jaime may do)
  ∩  Layer 2  agent ceiling     (uc3-actor registration ceiling_policies — the max the agent may EVER hold)
  ∩  Layer 3  per-request RAR   (vault:path_access — Vault narrows the token to this EXACT path this request)
  →  allow iff all three permit
```

The decisive property: **Vault is the interpreter of the RAR.** A JWT whose `vault:path_access` path matches the requested path is allowed; a JWT whose RAR path is anything else is **denied — even though the human baseline and the agent ceiling both permit the target path.** Enforcement happens at the point of use, inside Vault, per request. (Use Case 3's RAR is mandatory: the `uc3-actor` registration sets `optional_authorization_details = false`, so a delegated token with *no* RAR is rejected.)

:::alert{header="Migration: this replaces hand-rolled jwt bound_claims" type="info"}
Earlier iterations enforced delegation with a Vault **`jwt` auth backend** role (`uc3-jwt`) carrying `bound_claims` on `/may_act/sub = uc3-actor` (RFC 8693, *who may act*) and `/authorization_details/0/type = refund_approval` (the RAR *type*). That backend has been **removed**. The before/after:

| Concern | Before (removed `uc3-jwt` bound_claims) | After (native OAuth resource server) |
|---|---|---|
| Who may act | `bound_claims "/may_act/sub" = "uc3-actor"` on a jwt role | actor resolved from `act.sub = uc3-actor` against the Agent Registry |
| Max envelope | approximated by the flat `uc3-refund-writer` policy | `ceiling_policies` on the `uc3-actor` registration (true intersection) |
| Per-request scope | none — IVIA interpreted the RAR, Vault only presence-checked the *type* | `vault:path_access` RAR — **Vault** narrows the token to an exact path/capabilities per request |

The old `bound_claims` appear here only as the *before* of this migration; they are no longer a live control.
:::

## Step 1 — Point the CLI at Vault

```bash
pkill -f "kubectl port-forward -n vault svc/vault 8200:8200" 2>/dev/null; kubectl port-forward -n vault svc/vault 8200:8200 >/dev/null 2>&1 & sleep 2 && export VAULT_ADDR=http://localhost:8200 && export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json) && echo "Vault: $VAULT_ADDR"
```

## Step 2 — Inspect the `uc3-actor` registration and its ceiling

```bash
vault read agent-registry/registration/display-name/uc3-actor
```

Expected (key fields):

```
Key                               Value
---                               -----
display_name                      uc3-actor
ceiling_policies                  [uc3-agent-ceiling]
optional_authorization_details    false
```

- `display_name` `uc3-actor` — the actor Vault resolves from the delegated token's `act.sub` claim.
- `ceiling_policies` `[uc3-agent-ceiling]` — the maximum this agent may ever hold; it restricts, never grants.
- `optional_authorization_details` `false` — **the per-request `vault:path_access` RAR is mandatory** for Use Case 3. A delegated token without it is denied.

Read the ceiling — the envelope the agent is *ever* permitted to touch:

```bash
vault policy read uc3-agent-ceiling
```

Expected:

```hcl
path "database/creds/uc3-refund-writer" { capabilities = ["read"] }
path "database/creds/uc3-readonly"      { capabilities = ["read"] }
path "aws/sts/bedrock-reader"           { capabilities = ["read", "update"] }
path "aws/sts/uc3-logs-writer"          { capabilities = ["read", "update"] }
path "auth/token/lookup-self"           { capabilities = ["read"] }
path "sys/leases/renew"                 { capabilities = ["update"] }
```

The ceiling *permits* `database/creds/uc3-refund-writer` — but the token still only reaches it when the **per-request `vault:path_access` RAR** names that exact path. That is Layer 3 narrowing the ceiling down to a single path for a single request.

:::alert{header="Why the approved amount is not in the RAR" type="info"}
The `vault:path_access` RAR binds a **path** and **capabilities** — not a dollar amount. ISVAOP 25.10 does not expose the consent-time amount to any mapping rule at the token-exchange stage, and a path/capability grant cannot range-check a number regardless. The amount is consent-bound instead by three-plane audit correlation on `request_id` (see the [Three-Plane Audit Correlation](../74-three-plane-audit/) page): there is exactly one CIBA approval and one `banking.refunds` write under each `request_id`, so the amount written **is** the amount approved.
:::

## The DB Role: Time-Boxed Write Privileges

The `uc3-refund-writer` Vault database role issues ephemeral credentials with a default lifetime of 5 minutes (renewable to a hard ceiling of 10 minutes). The PostgreSQL role created at issuance time has only the minimum grants needed for a refund write:

```hcl
# vault_config/main.tf — uc3-refund-writer DB role
resource "vault_database_secret_backend_role" "uc3_refund_writer" {
  backend     = vault_mount.database.path
  name        = "uc3-refund-writer"
  db_name     = vault_database_secret_backend_connection.pg.name

  default_ttl = 300 # 5 minutes
  max_ttl     = 600 # 10 minutes — renewals permitted up to this ceiling

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
    "GRANT SELECT ON banking.accounts TO \"{{name}}\";",
    "GRANT SELECT ON banking.transactions TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON banking.refunds TO \"{{name}}\";",
    "ALTER ROLE \"{{name}}\" SET search_path TO banking,public;"
  ]

  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE USAGE ON SCHEMA banking FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}
```

After the credential lease expires the PostgreSQL role is dropped. Any attempt to reuse the credentials after expiry returns `FATAL: role does not exist`.

:::expand{header="Platform Track — the native primitives that wire the three layers"}
The `vault_config` Terraform module configures the OAuth resource server, the agent registration + ceiling, and the human/agent identity aliases (provider `hashicorp/vault >= 5.10.1`):

```hcl
resource "vault_activation_flags" "oauth_resource_server" {
  feature = "oauth-resource-server"
}

resource "vault_agent_registration" "uc3_actor" {
  entity_id                      = vault_identity_entity.uc3_actor.id
  display_name                   = "uc3-actor"
  ceiling_policies               = [vault_policy.uc3_agent_ceiling.name]
  optional_authorization_details = false   # RAR MANDATORY for UC3
}
```

The `uc3-actor` registration is resolved from the delegated token's `act.sub` claim. The human `jaime` has a subject alias keyed on `sub`; the agent has an actor alias keyed on `act.sub = uc3-actor`. On the on-behalf-of request Vault resolves **both** and intersects the human baseline with the agent ceiling, then narrows by the `vault:path_access` RAR.

Use Case 3 also keeps a **separate Kubernetes auth role (`uc3`)** for everything the agent does as *itself*, with no human in the picture: reading the model credentials it needs to answer at all (`aws/sts/bedrock-reader`), the credentials it writes its own audit records with (`aws/sts/uc3-logs-writer`), and read-only database credentials for listing transactions. That workload identity runs for the life of the pod and is deliberately powerless over refunds — `uc3-refund-writer` is reachable only through the delegated token, never through the Kubernetes role. CIBA initiation itself involves no Vault call at all; it is a request to IVIA.
:::

:::expand{header="Agent Dev Track — present the delegated JWT via X-Vault-Token"}
After the CIBA approval produces a delegated JWT, the Use Case 3 agent presents it **directly** to Vault — no login round-trip — and uses the vended credential for a single write:

```python
# vault_client.py — present the delegated OAuth JWT directly; Vault enforces the RAR
creds_resp = requests.get(f"{VAULT_ADDR}/v1/database/creds/uc3-refund-writer",
    headers={"X-Vault-Token": delegated_jwt})     # the JWT IS the token
db_user = creds_resp.json()["data"]["username"]
db_pass = creds_resp.json()["data"]["password"]

# Write refund using JIT credentials
conn = psycopg2.connect(host=RDS_HOST, dbname="workshop",
    user=db_user, password=db_pass)
```

The delegated JWT carries the `vault:path_access` RAR naming `database/creds/uc3-refund-writer`. Vault validates it, resolves `sub`/`act.sub`, intersects baseline ∩ ceiling ∩ RAR, and only then vends. The credentials are never cached; a new pair is fetched for each approved refund.
:::

## Verification

Read the registration, the DB role TTL, and (with the root token) prove JIT credential issuance:

```bash
kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$(jq -r .root_token ~/vault-init.json)" vault read agent-registry/registration/display-name/uc3-actor
```

```bash
kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$(jq -r .root_token ~/vault-init.json)" vault read database/roles/uc3-refund-writer
```

```bash
kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$(jq -r .root_token ~/vault-init.json)" vault read database/creds/uc3-refund-writer
```

The last command shows a dynamic username/password pair with `lease_duration` of 5 minutes. Repeat it after 5 minutes — the previous credentials will be gone. (The root token bypasses the RAR gate for this administrative check; a *delegated* token reaches this path only when its `vault:path_access` RAR names it, as the [next page](../73-bypass-test/) demonstrates.)
