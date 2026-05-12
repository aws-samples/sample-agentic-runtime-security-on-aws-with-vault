---
title: 'Verify Platform'
weight: 44
---

## Overview

Run the platform verification script to confirm that all platform components are healthy before proceeding to the use case modules.

## Step 1 — Run the verification script

```bash
bash infrastructure/scripts/test-vault-verify.sh
```

## Expected output

All checks should show `PASS`:

```
  ✓ PASS Vault pods running (3 of 3)
  ✓ PASS Vault seal status: unsealed
  ✓ PASS Vault Raft peers: 3
  ✓ PASS Vault audit device: enabled
  ✓ PASS IVIA pods running
  ✓ PASS IVIA OIDC discovery: issuer reachable
  ✓ PASS cert-manager pods running
  ✓ PASS AWS Load Balancer Controller running

 ✓ 8 check(s) passed
===============================================================================
```

If any check fails, the script prints a `Fix:` hint inline. Address the issue and re-run.

:::collapsible{header="What the script verifies"}
| Check | Command used | Pass condition |
|---|---|---|
| Vault pods running (3 of 3) | `kubectl get pods -n vault -l app.kubernetes.io/name=vault` | 3 pods in `Running` state |
| Vault seal status: unsealed | `kubectl exec vault-0 -- vault status -format=json \| jq -r .sealed` | `false` |
| Vault Raft peers: 3 | `kubectl exec vault-0 -- vault operator raft list-peers -format=json` | `servers \| length` == 3 |
| Vault audit device: enabled | `kubectl exec vault-0 -- vault audit list -format=json` | `length` >= 1 |
| IVIA pods running | `kubectl get pods -n verify-access` | at least 1 pod `Running` |
| IVIA OIDC discovery: issuer reachable | `kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never -n verify-access -- curl -sk https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration` | `issuer` field non-empty |
| cert-manager pods running | `kubectl get pods -n cert-manager` | at least 1 pod `Running` |
| AWS Load Balancer Controller running | `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller` | at least 1 pod `Running` |
:::

## What you just deployed

At this point the workshop platform layer is fully operational:

- **Vault 2.0 Raft HA** — 3 pods, KMS auto-unseal, Kubernetes + JWT auth methods, database and AWS secrets engines, audit device.
- **IBM IVIA 11.0.2** — OIDC provider with LDAP authentication against AWS Simple AD, OAuth clients for all use cases, ALB Ingress.
- **AWS Simple AD** — Lightweight managed Active Directory with pre-provisioned workshop users (Oscar, Adriana) for OAuth and CIBA flows.
- **OIDC seam** — Vault `jwt` auth trusts IVIA's OIDC discovery URL; user JWTs from IVIA become Vault-vended dynamic credentials.

Proceed to the use case modules to see these components in action.

## Troubleshooting

**Vault pods not running** — Check EKS node capacity (`kubectl get nodes`) and events (`kubectl describe pod -n vault vault-0`). Ensure the KMS key alias `vault-unseal` exists in the deployed region.

**Vault still sealed after init** — The KMS auto-unseal stanza requires the Vault IAM role to have `kms:Decrypt` and `kms:DescribeKey` on the unseal key. Check the Pod Identity association: `aws eks list-pod-identity-associations --cluster-name <name>`.

**IVIA pods in ImagePullBackOff** — The `ibm_entitlement_key` HCP Terraform variable is missing or incorrect. Update the workspace variable set and trigger a new workspace run.

**IVIA OIDC discovery not reachable** — The `verify-access` Service may not be ready. Run `kubectl get svc -n verify-access` and confirm `isvaop` has a ClusterIP. If the pod is Running but the service is not responsive, check the pod logs: `kubectl logs -n verify-access -l app=ivia`.

**cert-manager or AWS LBC not running** — These are deployed in the `addons` module. Trigger a new workspace run from HCP Terraform if they are missing.
