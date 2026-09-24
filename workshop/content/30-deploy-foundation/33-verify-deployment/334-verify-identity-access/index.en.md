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

**Why:** IVIA is the workshop's sign-in and consent authority. All seven pods have to be up, and the autoconf job that configured them has to have finished.

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

**Why:** Autoconf configures IVIA end to end and takes 4–6 minutes. Run this only if it has not finished yet — it blocks until it does.

```bash
kubectl wait --for=condition=complete job \
  -l app.kubernetes.io/name=ivia-autoconf \
  -n verify-access --timeout=10m
```

:::alert{header="STOP — only run this block if the ivia-autoconf Job shows STATUS=Error" type="warning"}
**Skip this block entirely if the autoconf Job shows `Completed` above** — the commands below DELETE working state. They are recovery-only.

If — and only if — `kubectl get pods -n verify-access` shows the autoconf Job with `STATUS=Error`, inspect the log to find the failure:

```bash
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf --tail=-1
```

`--tail=-1` is required: with a label selector (`-l`) `kubectl logs` defaults to showing only the last **10** lines, which is not enough to read the summary block. Look for the `API FAILURE SUMMARY` at the bottom of the output. To retry, remove the failed Job from Terraform state and re-apply:

```bash
terraform -chdir=infrastructure state rm 'module.ivia.kubernetes_job_v1.ivia_autoconf'
kubectl delete job -n verify-access -l app.kubernetes.io/name=ivia-autoconf
terraform -chdir=infrastructure apply
```
:::

## Step 2 — Confirm the WRP ALB Ingress

**Why:** This is the load balancer browsers reach IVIA through. One certificate covers both it and the banking app, because they share an IngressGroup.

```bash
kubectl get ingress -n verify-access
```

Expected — one ALB Ingress with an `ADDRESS` like `k8s-workshopacme-<hash>.<region>.elb.amazonaws.com`. The shared `workshop-acme` IngressGroup fronts both this WRP Ingress and the banking-UI Ingress, so one Let's Encrypt cert covers both workshop FQDNs.

**Why:** The certificate was issued for the workshop FQDN, not the raw ALB hostname. This reads that name out and puts it in `$WRP_HOST` for the next two steps.

```bash
source infrastructure/.acme-state && WRP_HOST="$NIP_FQDN_WRP" && echo "WRP host: $WRP_HOST"
```

Compare this value; don't open it. The bare host serves a login page that takes your password and goes nowhere — sign in at the **banking** URL, on the [OAuth Login Flow](../../../60-use-case-2/61-oauth-pkce-flow/) page.

:::alert{header="Trusted cert vs. raw ALB" type="info"}
The browser and mobile app validate against the workshop FQDN (`NIP_FQDN_WRP`), not the raw `k8s-workshopacme-*.elb.amazonaws.com` hostname — hitting the raw host shows a TLS warning, which is expected. `deploy-workshop.sh` Step 7 issued that trusted Let's Encrypt cert and wrote `.acme-state`. If Step 7 failed, return to page 31 and re-run.
:::

## Step 3 — Confirm OIDC discovery via WRP junction

Browser flows reach the OIDC Provider through the WRP `/isvaop` junction:

**Why:** This asks IVIA who it says it is, over the same path a browser takes. There is deliberately no `-k`, so a success also proves the certificate is genuinely trusted.

```bash
curl -s "https://$WRP_HOST/isvaop/oauth2/.well-known/openid-configuration" | jq .issuer
```

Expected:

```
"https://<NIP_FQDN_WRP>"
```

A `curl: (60) SSL certificate problem` here means Step 7's ACME issuance did not complete — check `kubectl get certificate workshop-le-tls -n cert-manager` shows `READY=True`.

## Step 4 — Confirm internal OIDC discovery

**Why:** Vault and the agents reach IVIA from inside the cluster, not through the load balancer. This checks they are told the same issuer a browser is — if the two disagreed, token validation would fail later.

```bash
kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never --quiet -n verify-access -- curl -sk https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration </dev/null | jq .issuer
```

Expected — the **same** issuer as Step 3, even reached over ClusterIP. The provider always advertises the one public WRP issuer, which lets Vault validate IVIA tokens against a single `issuer_id` on its OAuth resource server profile:

```
"https://<NIP_FQDN_WRP>"
```
