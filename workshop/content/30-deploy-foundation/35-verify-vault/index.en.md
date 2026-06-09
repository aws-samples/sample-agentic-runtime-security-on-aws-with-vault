---
title: 'Validate Vault'
weight: 35
---

Vault was deployed as a 3-node Raft HA cluster, initialized, and unsealed by `terraform apply` plus `deploy-workshop.sh`. Confirm it is healthy before proceeding.

![Vault authorization flow — ephemeral, per-request credentials across Use Cases 1, 2, and 3](/static/images/vault-authorization-flow.svg)

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
