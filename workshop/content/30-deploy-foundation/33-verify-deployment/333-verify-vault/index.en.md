---
title: 'Validate Vault'
weight: 333
---

Vault was deployed as a 3-node Raft HA cluster, initialized, and unsealed as part of Tier 2 — during your account setup at an event, or by your own `deploy-workshop.sh` run when self-paced. Confirm it is healthy before proceeding.

![Vault authorization flow — ephemeral, per-request credentials across Use Cases 1, 2, and 3](/static/images/vault-authorization-flow.png)

The Vault root token lives at `~/vault-init.json`. How it got there depends on your path:

- **At an event** — you pulled it from the state bucket in Step 3 of [Deploy — At an Event](../../31-deploy-at-an-event/). `vault-init.sh` ran inside the account-setup build, not on your machine, so there is no local run to go looking for.
- **Self-paced** — `vault-init.sh` (run by `deploy-workshop.sh`) wrote it during Tier-2 initialization.

**Why:** Steps 3, 4 and 5 read Vault as an administrator. This loads that token into your shell so those commands work.

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
```

## Step 1 — Confirm pods are Running

**Why:** Vault runs as three servers, not one. All three have to be up before the cluster can elect a leader and serve credentials.

```bash
kubectl get pods -n vault
```

Expected — the three Vault server pods `Running`, plus the agent-injector:

```
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 1/1     Running   0          5m
vault-1                                 1/1     Running   0          4m
vault-2                                 1/1     Running   0          4m
vault-agent-injector-<hash>             1/1     Running   0          5m
```

`vault-0`, `vault-1` and `vault-2` are the Raft cluster. Remember there are three of them — some later steps read Vault's audit log, and the node that served a request is the one that logged it.

## Step 2 — Confirm KMS auto-unseal

**Why:** A sealed Vault holds its data but answers nothing. AWS KMS unseals it automatically, so nobody has to hold unseal keys during the workshop.

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

**Why:** This proves the three servers actually formed one cluster with a leader, rather than three servers sitting alone.

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

**Why:** Every use case ends by finding its own request in Vault's audit log. Without an audit device there is nothing to find.

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault audit list"
```

Expected — at least one audit device listed. If the list is empty, `deploy-workshop.sh` has not completed successfully — re-run it.

## Step 5 — Confirm Vault Enterprise + the Agent Registry

The native agent-identity model this workshop teaches — the **Agent Registry** and the **OAuth resource server** — is a Vault **Enterprise** capability. Confirm the running binary is Enterprise and that the Agent Registry secrets engine is mounted before you rely on either.

**Why:** The Agent Registry is an Enterprise feature. If this binary is not Enterprise, nothing the workshop teaches about agent identity will work.

```bash
kubectl exec -n vault vault-0 -- vault status | grep -i version
```

Expected — the `+ent` suffix marks an Enterprise build:

```
Version                 2.0.3+ent
```

**Why:** This confirms the Agent Registry is mounted alongside the engines that vend database and AWS credentials.

```bash
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault secrets list" | grep -E 'agent-registry|database|aws'
```

Expected — `agent-registry/`, `aws/`, and `database/` all listed. Note the engine **type** is `agent_registry` with an underscore, while its mount **path** uses a hyphen:

```
agent-registry/    agent_registry    agent-registry_<id>    agent registry
aws/               aws               aws_<id>               n/a
database/          database          database_<id>          n/a
```

If `agent-registry/` is missing, the Enterprise license does not carry the `agentic-iam` feature that unlocks the Agent Registry + OAuth resource server — re-check the license and re-run `deploy-workshop.sh`.

**Why:** Each Use Case agent has a named identity in Vault, the same way a person does. Seeing all three listed means the registry is populated and ready.

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
