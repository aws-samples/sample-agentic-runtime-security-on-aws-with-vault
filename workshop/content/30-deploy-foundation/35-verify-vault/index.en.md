---
title: 'Validate Vault'
weight: 35
---

Vault was deployed as a 3-node Raft HA cluster, initialized, and unsealed by `terraform apply` plus `deploy-workshop.sh`. Confirm it is healthy before proceeding.

![Vault authorization flow — ephemeral, per-request credentials across Use Cases 1, 2, and 3](/static/images/vault-authorization-flow.png)

:::alert{header="Root token location" type="info"}
`vault-init.sh` (run by `deploy-workshop.sh`) wrote the Vault root token to `~/vault-init.json` during initialization. Load it before running the authenticated checks below:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
```
:::

## Step 1 — Confirm pods are Running

```bash
kubectl get pods -n vault
```

Expected — all three pods `Running`:

```
NAME      READY   STATUS    RESTARTS   AGE
vault-0   1/1     Running   0          5m
vault-1   1/1     Running   0          4m
vault-2   1/1     Running   0          4m
```

## Step 2 — Confirm KMS auto-unseal

```bash
kubectl exec -n vault vault-0 -- vault status
```

Expected — `Sealed: false` confirms KMS auto-unseal is active:

```
Key                      Value
---                      -----
Seal Type                awskms
Recovery Seal Type       shamir
Initialized              true
Sealed                   false
...
```

## Step 3 — Confirm Raft peers

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault operator raft list-peers"
```

Expected — three peers, one leader:

```
Node       Address                        State       Voter
----       -------                        -----       -----
vault-0    vault-0.vault-internal:8201    leader      true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
```

## Step 4 — Confirm audit device

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault audit list"
```

Expected — at least one audit device listed. If the list is empty, `deploy-workshop.sh` has not completed successfully — re-run it.

## Step 5 — Confirm Vault Enterprise + the Agent Registry

The native agent-identity model this workshop teaches — the **Agent Registry** and the **OAuth resource server** — is a Vault **Enterprise** capability. Confirm the running binary is Enterprise and that the Agent Registry secrets engine is mounted before you rely on either.

Enterprise edition — the reported server `Version` ends in `+ent`:

```bash
kubectl exec -n vault vault-0 -- vault status | grep -i version
```

Expected — the `+ent` suffix marks an Enterprise build:

```
Version             2.0.3+ent
Build Date          2026-...
```

Agent Registry mount present alongside the database and AWS secrets engines:

```bash
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault secrets list" | grep -E 'agent-registry|database|aws'
```

Expected — `agent-registry/`, `aws/`, and `database/` all listed:

```
agent-registry/    agent-registry    n/a
aws/               aws               n/a
database/          database          n/a
```

If `agent-registry/` is missing, the Enterprise license does not carry the `agentic-iam` feature that unlocks the Agent Registry + OAuth resource server — re-check the license and re-run `deploy-workshop.sh`.

List the three workshop agent registrations Vault knows about — each Use Case agent has a first-class, named identity in the registry:

```bash
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault list agent-registry/registration/display-name"
```

Expected — the three registered agents:

```
Keys
----
agent-uc2
uc1-agent
uc3-actor
```

You will inspect each registration's `ceiling_policies` on its Use Case page. For now, seeing all three confirms the registry is populated and the native model is ready.
