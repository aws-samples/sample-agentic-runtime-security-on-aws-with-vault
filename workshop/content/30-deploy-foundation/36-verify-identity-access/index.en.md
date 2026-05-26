---
title: 'Validate Identity Access'
weight: 36
---

IBM Verify Identity Access (IVIA) runs as a self-contained seven-pod stack in the `verify-access` namespace. The autoconf Job configured it fully unattended — confirm all pods are healthy and OIDC is serving before continuing.

![IBM Verify Identity Access — self-contained seven-pod stack on EKS](/static/images/ivia-stack.svg)

:::collapsible{header="Pod reference — what each pod does"}
| Pod | Role |
|-----|------|
| `iviaconfig` | Local Management Interface (LMI) — single source of truth, publishes configuration snapshots |
| `iviawrprp1` | Web Reverse Proxy — browser entry point, junction routing, session management |
| `iviaruntime` | AAC Runtime — Advanced Access Control authentication engine |
| `iviaop` | OIDC Provider — OAuth 2.0 token issuance, JWKS, CIBA, mapping rules |
| `iviadsc` | Distributed Session Cache — session store |
| `openldap` | In-cluster LDAP directory (LDAPS `:636`) — user registry (Oscar, Jaime) |
| `postgresql` | In-cluster PostgreSQL HVDB (`:5432`) — IVIA runtime DB, sessions, cluster store |
:::

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

### Autoconf failure

If the autoconf job shows `Error`, inspect the log:

```bash
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf
```

Look for the `API FAILURE SUMMARY` at the bottom. To retry, remove the failed Job from Terraform state and re-apply:

```bash
terraform -chdir=infrastructure state rm 'module.ivia.kubernetes_job_v1.ivia_autoconf'
kubectl delete job -n verify-access -l app.kubernetes.io/name=ivia-autoconf
terraform -chdir=infrastructure apply
```

## Step 2 — Confirm the WRP ALB Ingress

```bash
kubectl get ingress -n verify-access
```

Expected:

```
NAME       CLASS   HOSTS   ADDRESS                                        PORTS   AGE
ivia-wrp   alb     *       k8s-verifyac-ivia-xxxx.elb.amazonaws.com      80      8m
```

Save the WRP hostname for the next check:

```bash
WRP_HOST=$(kubectl get ingress -n verify-access ivia-wrp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "WRP host: $WRP_HOST"
```

> The PORTS column shows `80`, but the ALB also listens on port 443 with an SSL redirect active — all browser and API traffic is served over HTTPS.

## Step 3 — Confirm OIDC discovery via WRP junction

Browser flows reach the OIDC Provider through the WRP `/isvaop` junction:

```bash
curl -sk "https://$WRP_HOST/isvaop/oauth2/.well-known/openid-configuration" | jq .issuer
```

Expected:

```
"https://<wrp-alb-hostname>"
```

## Step 4 — Confirm internal OIDC discovery

Vault and agent workloads reach the OIDC Provider via its ClusterIP service. Verify from inside the cluster:

```bash
kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never \
  -n verify-access -- \
  curl -sk https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration \
  | jq .issuer
```

Expected:

```
"https://iviaop.verify-access.svc.cluster.local:8436/oauth2"
```
