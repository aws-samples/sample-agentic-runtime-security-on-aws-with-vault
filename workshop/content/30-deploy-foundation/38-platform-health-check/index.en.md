---
title: 'Platform Health Check'
weight: 38
---

Run one script to confirm the entire platform layer is healthy before proceeding to the use case modules.

## Step 1 — Run the verification script

```bash
bash infrastructure/scripts/test-vault-verify.sh
```

Expected — all 13 checks `PASS`. The last five are the Vault Enterprise checks: they prove your licence actually carries the features this workshop teaches, and that the retired `jwt` auth backend is gone:

```
  ✓ PASS Vault pods running (3 of 3)
  ✓ PASS Vault seal status: unsealed
  ✓ PASS Vault Raft peers: 3
  ✓ PASS Vault audit device: enabled (1 device(s))
  ✓ PASS IVIA pods running (7 pod(s))
  ✓ PASS IVIA OIDC discovery: issuer reachable (https://<NIP_FQDN_WRP>)
  ✓ PASS cert-manager pods running (3 pod(s))
  ✓ PASS AWS Load Balancer Controller running (2 pod(s))
  ✓ PASS Vault Enterprise edition (version=2.0.3+ent; sys/license/status responds)
  ✓ PASS Secrets engines mounted: database/ + aws/ (platform-standard license present; pki-only absent)
  ✓ PASS Agent Registry responds — registration 'uc1-agent' resolvable by display-name (agentic-iam present)
  ✓ PASS OAuth resource server profile 'ivia' responds (feature active + profile applied)
  ✓ PASS jwt/ auth mount is ABSENT — retired IVIA jwt backend removed (decision (e) cutover proof)

===============================================================================
 ✓ 13 check(s) passed
===============================================================================
```

If any check fails, the script prints a `Fix:` hint inline. Address the issue and re-run.

::::expand{header="What the script verifies"}
| Check | Command used | Pass condition |
|---|---|---|
| Vault pods running (3 of 3) | `kubectl get pods -n vault -l app.kubernetes.io/name=vault` | 3 pods in `Running` state |
| Vault seal status: unsealed | `kubectl exec vault-0 -- vault status -format=json \| jq -r .sealed` | `false` |
| Vault Raft peers: 3 | `kubectl exec vault-0 -- vault operator raft list-peers -format=json` | `servers \| length` == 3 |
| Vault audit device: enabled | `kubectl exec vault-0 -- vault audit list -format=json` | `length` >= 1 |
| IVIA pods running | `kubectl get pods -n verify-access` | at least 1 pod `Running` |
| IVIA OIDC discovery: issuer reachable | `curl -sk https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration` | `issuer` field non-empty |
| cert-manager pods running | `kubectl get pods -n cert-manager` | at least 1 pod `Running` |
| AWS Load Balancer Controller running | `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller` | at least 1 pod `Running` |
| Vault Enterprise edition | `vault status` + `vault read sys/license/status` | `version` ends in `+ent` and the licence endpoint responds |
| Secrets engines mounted | `vault secrets list` | both `database/` and `aws/` present — proves a platform-standard licence, not pki-only |
| Agent Registry responds | `vault read agent-registry/registration/display-name/uc1-agent` | registration resolvable — proves the `agentic-iam` feature is licensed |
| OAuth resource server profile `ivia` responds | `vault read sys/config/oauth-resource-server/ivia` | profile readable — the feature is active and the profile applied |
| `jwt/` auth mount is ABSENT | `vault auth list -format=json` | `jwt/` **not** present — proof the retired IVIA jwt backend was removed in the native cutover |
::::
