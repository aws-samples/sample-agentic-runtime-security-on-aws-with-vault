---
title: 'Deploy Vault'
weight: 41
---

## Overview

In this step you deploy HashiCorp Vault 2.0 on EKS as a 3-node Raft HA cluster. Each Vault pod is scheduled to a distinct Availability Zone. Auto-unseal is handled by a dedicated AWS KMS key accessed through EKS Pod Identity — Vault pods never touch AWS credentials directly.

## Step 1 — Review the Vault module

Open `infrastructure/main.tf` and locate the `vault` module block. Notice that it depends on `module.addons` (which enables cert-manager and AWS Load Balancer Controller).

The `vault` module calls `infrastructure/modules/vault/` which provisions:

- A dedicated KMS key (`alias/vault-unseal`) with a key policy restricted to the Vault service account.
- An EKS Pod Identity association binding the Vault Kubernetes ServiceAccount to an IAM role with `kms:Decrypt` and `kms:DescribeKey` permissions.
- A Helm release of the `hashicorp/vault` chart with `server.ha.enabled=true`, `server.ha.raft.enabled=true`, and three replicas.

## Step 2 — Already deployed

The `vault` module was deployed as part of the foundation `terraform apply` in the previous module. The `vault` module applies after `addons` completes (enforced by `depends_on` in `main.tf`). No separate apply step is needed.

## Step 3 — What happens during apply

When the `vault` module applies:

1. A dedicated KMS key is created with alias `alias/vault-unseal`. This key is separate from the workshop CMK (`alias/workshop-data`) — a deliberate decision for audit-correlation clarity in Phase 6.
2. An IAM role is created and an EKS Pod Identity association is registered for the `vault` Kubernetes ServiceAccount in the `vault` namespace.
3. The `hashicorp/vault` Helm chart is deployed with `server.ha.raft.enabled=true` and `replicas=3`. The chart creates 3 StatefulSet pods (`vault-0`, `vault-1`, `vault-2`).
4. The Helm chart configures the KMS unseal stanza pointing to the key ID from step 1. Pods will auto-unseal via KMS on every restart — no manual unseal required after the first initialization.
5. cert-manager and AWS Load Balancer Controller (deployed in the `addons` module) are available for Vault Ingress and TLS if needed.

## Step 4 — Verify pods are running

After the apply completes:

```bash
kubectl get pods -n vault
```

Expected output — all three pods `Running`:

```
NAME      READY   STATUS    RESTARTS   AGE
vault-0   1/1     Running   0          3m
vault-1   1/1     Running   0          2m
vault-2   1/1     Running   0          2m
```

Check Vault status on the leader:

```bash
kubectl exec -n vault vault-0 -- vault status
```

At this point the output will show `Sealed: true` — Vault is running but not yet initialized. Proceed to Step 5.

## Step 5 — Initialize Vault (one-time)

Vault initialization is a **one-time operation**. Run it on `vault-0`:

```bash
kubectl exec -it -n vault vault-0 -- \
  vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json | tee ~/vault-init.json
```

> **Workshop note:** `-key-shares=1 -key-threshold=1` is workshop-grade for simplicity. In production use at least 5 shares with a threshold of 3, distributed to separate key custodians.

The command outputs a JSON object. Extract and save the root token:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
echo "Root token: $VAULT_ROOT_TOKEN"
```

Because KMS auto-unseal is configured, **all three Vault pods will unseal automatically** without the recovery key. Verify:

```bash
kubectl exec -n vault vault-0 -- vault status
```

```
Key                      Value
---                      -----
Seal Type                awskms
Recovery Seal Type       shamir
Initialized              true
Sealed                   false
...
```

`Sealed: false` confirms KMS auto-unseal is working.

## Step 6 — Verify Raft peers

```bash
kubectl exec -n vault vault-0 -- \
  vault login -no-print "$VAULT_ROOT_TOKEN" && \
  vault operator raft list-peers
```

Expected output shows all three nodes:

```
Node       Address                        State       Voter
----       -------                        -----       -----
vault-0    vault-0.vault-internal:8201    leader      true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
```

:::alert{header="Root token security" type="warning"}
The root token is a break-glass credential. Store it securely (for example, in AWS Secrets Manager or a hardware token) and do not use it for day-to-day operations. In production, generate a narrowly scoped token via Vault Agent + AppRole and revoke the root token. For this workshop the root token is used in the next module to configure the OIDC seam.
:::

:::collapsible{header="Module reference — Helm chart values summary"}
The `vault` module passes the following key values to the Vault Helm chart:

| Value | Setting |
|---|---|
| `server.ha.enabled` | `true` |
| `server.ha.replicas` | `3` |
| `server.ha.raft.enabled` | `true` |
| `server.ha.raft.setNodeId` | `true` |
| `server.serviceAccount.create` | `false` (SA owned by Terraform Pod Identity) |
| `server.extraEnvironmentVars.VAULT_SEAL_TYPE` | `awskms` |
| `server.extraEnvironmentVars.VAULT_AWSKMS_SEAL_KEY_ID` | KMS key ARN |
| `auditStorage.enabled` | `false` (audit logs go to stdout via `-log-format=json`) |
| `server.logFormat` | `json` |

The Vault audit device that writes to the `/workshop/vault-audit` CloudWatch log group is configured in the `vault_config` module (next module), not the Helm chart.
:::
