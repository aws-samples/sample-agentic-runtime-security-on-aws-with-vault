---
title: 'Validate Identity Access'
weight: 334
---

IBM Verify Identity Access (IVIA) runs as a self-contained seven-pod stack in the `verify-access` namespace. The autoconf Job configured it fully unattended — confirm all pods are healthy and OIDC is serving before continuing.

![IBM Verify Identity Access — self-contained seven-pod stack on EKS](/static/images/ivia-stack.png)

::::expand{header="Pod reference — what each pod does"}
| Pod | Role |
|-----|------|
| `iviaconfig` | Local Management Interface (LMI) — single source of truth, publishes configuration snapshots |
| `iviawrprp1` | Web Reverse Proxy — browser entry point, junction routing, session management |
| `iviaruntime` | AAC Runtime — Advanced Access Control authentication engine |
| `iviaop` | OIDC Provider — OAuth 2.0 token issuance, JWKS, CIBA, mapping rules |
| `iviadsc` | Distributed Session Cache — session store |
| `openldap` | In-cluster LDAP directory (LDAPS `:636`) — user registry (Oscar, Jaime) |
| `postgresql` | In-cluster PostgreSQL HVDB (`:5432`) — IVIA runtime DB, sessions, cluster store |
::::

## Step 1 — Confirm all pods are Running

```bash
kubectl get pods -n verify-access
```

Expected — seven pods `Running` and the autoconf job `Completed`:

```
NAME                           READY   STATUS      RESTARTS   AGE
iviaconfig-<hash>              1/1     Running     0          12m
iviadsc-<hash>                 1/1     Running     0          8m
iviaop-<hash>                  1/1     Running     0          8m
iviaruntime-<hash>             1/1     Running     0          8m
iviawrprp1-<hash>              1/1     Running     0          8m
openldap-<hash>                1/1     Running     0          12m
postgresql-<hash>              1/1     Running     0          12m
ivia-autoconf-<hash>           0/1     Completed   0          10m
```

If the autoconf job is still running, wait for it to complete (typically 4–6 minutes):

```bash
kubectl wait --for=condition=complete job \
  -l app.kubernetes.io/name=ivia-autoconf \
  -n verify-access --timeout=10m
```

:::alert{header="STOP — only run this block if the ivia-autoconf Job shows STATUS=Error" type="warning"}
**Skip this block entirely if the autoconf Job shows `Completed` above** — the commands below DELETE working state. They are recovery-only.

If — and only if — `kubectl get pods -n verify-access` shows the autoconf Job with `STATUS=Error`, inspect the log to find the failure:

```bash
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf
```

Look for the `API FAILURE SUMMARY` at the bottom. To retry, remove the failed Job from Terraform state and re-apply:

```bash
terraform -chdir=infrastructure state rm 'module.ivia.kubernetes_job_v1.ivia_autoconf'
kubectl delete job -n verify-access -l app.kubernetes.io/name=ivia-autoconf
terraform -chdir=infrastructure apply
```
:::

## Step 2 — Confirm the WRP ALB Ingress

```bash
kubectl get ingress -n verify-access
```

Expected — one ALB Ingress with an `ADDRESS` like `k8s-workshopacme-<hash>.<region>.elb.amazonaws.com`. The shared `workshop-acme` IngressGroup fronts both this WRP Ingress and the banking-UI Ingress, so one Let's Encrypt cert covers both nip.io FQDNs.

The hostname the browser trusts is the **nip.io FQDN** the cert was issued for — read it from `.acme-state`, not the raw ALB hostname:

```bash
source infrastructure/.acme-state && WRP_HOST="$NIP_FQDN_WRP" && echo "WRP host: $WRP_HOST"
```

:::alert{header="Trusted cert vs. raw ALB" type="info"}
The browser and mobile app validate against the nip.io FQDN (`NIP_FQDN_WRP`), not the raw `k8s-workshopacme-*.elb.amazonaws.com` hostname — hitting the raw host shows a TLS warning, which is expected. `deploy-workshop.sh` Step 7 issued that trusted Let's Encrypt cert and wrote `.acme-state`. If Step 7 failed, return to page 31 and re-run.
:::

## Step 3 — Confirm OIDC discovery via WRP junction

Browser flows reach the OIDC Provider through the WRP `/isvaop` junction:

```bash
curl -sk "https://$WRP_HOST/isvaop/oauth2/.well-known/openid-configuration" | jq .issuer
```

Expected:

```
"https://<NIP_FQDN_WRP>"
```

## Step 4 — Confirm internal OIDC discovery

Vault and agent workloads reach the OIDC Provider via its ClusterIP service. Verify from inside the cluster (the `--quiet` flag keeps `kubectl run`'s pod-lifecycle messages out of the `jq` pipe):

```bash
kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never --quiet -n verify-access -- curl -sk https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration </dev/null | jq .issuer
```

Expected — the **same** issuer as Step 3, even reached over ClusterIP. The provider always advertises the one public WRP issuer, which lets Vault validate IVIA tokens against a single `bound_issuer`:

```
"https://<NIP_FQDN_WRP>"
```
