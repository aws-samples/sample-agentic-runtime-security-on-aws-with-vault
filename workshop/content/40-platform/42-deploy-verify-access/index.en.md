---
title: 'Deploy Verify Access'
weight: 42
---

## Overview

IBM Verify Identity Access (IVIA) runs as a **self-contained seven-pod stack** in the `verify-access` namespace — four IVIA containers plus three supporting services they depend on. Critically, the directory and database are **in-cluster pods**, not AWS Simple AD or the shared workshop RDS:

| Pod | Image | Role |
|-----|-------|------|
| `iviaconfig` | `icr.io/ivia/ivia-config:11.0.2.0` | Local Management Interface (LMI) — single source of truth, publishes configuration snapshots |
| `iviawrprp1` | `icr.io/ivia/ivia-wrp:11.0.2.0` | Web Reverse Proxy — browser entry point, junction routing, session management |
| `iviaruntime` | `icr.io/ivia/ivia-runtime:11.0.2.0` | AAC Runtime — Advanced Access Control authentication engine |
| `iviaop` | `icr.io/ivia/ivia-oidc-provider:25.10` | OIDC Provider — OAuth 2.0 token issuance, JWKS, CIBA, mapping rules |
| `iviadsc` | `icr.io/ivia/ivia-dsc:11.0.2.0` | Distributed Session Cache — db-backed session store |
| `openldap` | `icr.io/isva/verify-access-openldap:10.0.6.0` | In-cluster LDAP directory (LDAPS `:636`) — federated user registry (Oscar, Adriana) |
| `postgresql` | `icr.io/ivia/ivia-postgresql:11.0.2.0` | In-cluster PostgreSQL HVDB (`:5432`) — IVIA runtime DB, sessions, cluster store |

**Traffic routing:** The WRP is the single internet-facing entry point for all browser-based flows (CIBA consent, authorization_code login). Machine-to-machine flows (CIBA bc-authorize, token exchange, ROPC) bypass WRP and hit the OIDC Provider directly via its internal ClusterIP service.

## Architecture

![IBM Verify Identity Access — self-contained seven-pod stack on EKS](/static/images/ivia-stack.svg)

## Deployment Sequence

The `depends_on` chain enforces this exact startup order:

1. **Config container (`ivia-config`) starts** — LMI available on ClusterIP port 9443. All other containers depend on Config being ready before they can pull configuration snapshots.

2. **Manual trial activation** — IVIA locks all `/isam/*` API endpoints until the trial license is activated via the LMI web UI. This step cannot be automated via the REST API.

3. **Autoconf Job runs** — configures the in-cluster PostgreSQL HVDB, runtime environment, OpenLDAP federated directory, WRP instance, `/isvaop` junction, CIBA consent ACL, and cfgsvc credentials. Publishes the configuration snapshot after each phase.

4. **Runtime (`ivia-runtime`) and WRP (`ivia-wrp`) start in parallel** — both download the published snapshot from Config via `CONFIG_SERVICE_URL`. WRP's ALB Ingress replaces the old OIDC Provider ALB as the external entry point.

## What Terraform Deploys

The `verify_access` module creates (all in the `verify-access` namespace):

- Config / LMI (`iviaconfig`, `ivia-config:11.0.2.0`) — Deployment, ClusterIP Service, PersistentVolumeClaim
- Web Reverse Proxy (`iviawrprp1`, `ivia-wrp:11.0.2.0`) — Deployment, ClusterIP Service, ALB Ingress (internet-facing)
- AAC Runtime (`iviaruntime`, `ivia-runtime:11.0.2.0`) — Deployment, ClusterIP Service
- OIDC Provider (`iviaop`, `ivia-oidc-provider:25.10`) — Deployment, ClusterIP Service; reachable via the WRP `/isvaop` junction and directly at ClusterIP `:8436` for machine-to-machine flows
- Distributed Session Cache (`iviadsc`, `ivia-dsc:11.0.2.0`) — Deployment, ClusterIP Service
- In-cluster OpenLDAP directory (`openldap`, `verify-access-openldap:10.0.6.0`) — Deployment, ClusterIP Service (LDAPS `:636`); the federated user registry, replacing AWS Simple AD
- In-cluster PostgreSQL HVDB (`postgresql`, `ivia-postgresql:11.0.2.0`) — Deployment, ClusterIP Service (`:5432`); IVIA's runtime DB / sessions / cluster store — pod-local, **not** the shared workshop RDS
- Autoconf Kubernetes Job (`ivia-autoconf`) — configures the HVDB, runtime, OpenLDAP federated directory, WRP instance, `/isvaop` junction, and ACLs
- ICR pull secret for all seven containers

## Step 1 — Verify all pods are running

The `verify_access` module was deployed as part of the foundation `terraform apply` in the previous module. No separate apply step is needed. Verify all seven pods are healthy:

```bash
kubectl get pods -n verify-access
```

Expected output — seven pods Running:

```
NAME                           READY   STATUS    RESTARTS   AGE
iviaconfig-<hash>              1/1     Running   0          12m
iviadsc-<hash>                 1/1     Running   0          8m
iviaop-<hash>                  1/1     Running   0          8m
iviaruntime-<hash>             1/1     Running   0          8m
iviawrprp1-<hash>              1/1     Running   0          8m
openldap-<hash>                1/1     Running   0          12m
postgresql-<hash>              1/1     Running   0          12m
```

:::alert{header="Config must start first" type="warning"}
If `ivia-runtime` or `ivia-wrp` pods fail to start with `CrashLoopBackOff`, check whether `ivia-config` is Running. Runtime and WRP cannot download their configuration snapshot until Config's LMI is available. The autoconf Job also requires Config to be ready before it can publish the initial snapshot.
:::

## Step 2 — Wait for the autoconf Job to complete

The `ibmvia_autoconf` SDK provisions IVIA **fully unattended** via the LMI REST
API — no browser, no port-forward, no manual clicks required. It accepts the
SLA, uploads the trial license, sets the cfgsvc service-account password,
configures the runtime database + DSC + reverse-proxy + junctions + ACLs +
OIDC LUA transforms, and publishes the configuration snapshot.

Wait for the Job to complete (typically 4-6 minutes):

```bash
kubectl wait --for=condition=complete job \
  -l app.kubernetes.io/name=ivia-autoconf \
  -n verify-access --timeout=10m
```

Tail the log if you want to watch the progression:

```bash
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf -f
```

After the Job completes, the four deferred IVIA pods (`iviaruntime`,
`iviadsc`, `iviaop`, `iviawrprp1`) download the snapshot from the LMI and
transition to `1/1 Ready` within ~60 seconds. Verify:

```bash
kubectl get pods -n verify-access
```

All seven IVIA pods should be `1/1 Running` and `ivia-autoconf-<hash>` should
be `Completed`.

:::alert{header="If autoconf fails" type="warning"}
The Job spec sets `backoff_limit=0` and `restart_policy=Never`, so a failed pod
sticks around for inspection rather than retrying with backoff. Grab the full
log:

```bash
kubectl logs -n verify-access <autoconf-pod-name> -c autoconf
```

Look at the API FAILURE SUMMARY at the bottom of the output. To retry, remove
the failed Job from terraform state and from the cluster, then re-run
`terraform apply`:

```bash
terraform state rm 'module.ivia.kubernetes_job_v1.ivia_autoconf'
kubectl delete job -n verify-access <autoconf-job-name>
terraform apply
```
:::

:::collapsible{header="When would I ever need to access the LMI manually?"}
The LMI is intentionally **not exposed externally** — it's an admin surface that
should never reach the public internet. If you're debugging an autoconf failure
or want to inspect the appliance state, you can port-forward to it:

```bash
kubectl port-forward -n verify-access svc/iviaconfig 9443:9443
```

Then open `https://localhost:9443` and log in as `admin` with the password from:

```bash
kubectl get secret iviaadmin -n verify-access \
  -o jsonpath='{.data.adminpw}' | base64 -d; echo
```

In normal workshop deployment you will never need to do this.
:::

## Step 3 — Check the WRP ALB Ingress

```bash
kubectl get ingress -n verify-access
```

Expected output:

```
NAME       CLASS   HOSTS   ADDRESS                                        PORTS   AGE
ivia-wrp   alb     *       k8s-verifyac-ivia-xxxx.elb.amazonaws.com      80      8m
```

The WRP ALB hostname is the external entry point for all browser flows. Save it:

```bash
WRP_HOST=$(kubectl get ingress -n verify-access ivia-wrp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "WRP host: $WRP_HOST"
```

## Step 4 — Verify OIDC discovery via WRP junction

The OIDC Provider is accessible externally via the WRP `/isvaop` junction:

```bash
curl -s "http://$WRP_HOST/isvaop/oauth2/.well-known/openid-configuration" | jq .issuer
```

Expected:

```
"http://<wrp-alb-hostname>/isvaop"
```

Vault's JWT auth method uses the **internal ClusterIP** URL (not the WRP ALB) as `bound_issuer`:

```bash
kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never \
  -n verify-access -- \
  curl -sk https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration \
  | jq .issuer
```

Expected:

```
"https://isvaop.verify-access.svc.cluster.local:8436/oauth2"
```

:::collapsible{header="Why raw Kubernetes manifests instead of Helm?"}
IBM Verify Identity Access does not publish a Helm chart. The `verify_access` Terraform module uses the `kubernetes` provider to manage each Kubernetes resource as a Terraform resource (`kubernetes_namespace`, `kubernetes_secret`, `kubernetes_deployment`, `kubernetes_service`, `kubernetes_ingress_v1`).

Using the `kubernetes` provider (rather than `kubectl_manifest` with raw YAML) keeps the full configuration visible as Terraform HCL. Attendees can read the exact Deployment spec, resource requests, environment variables, and volume mounts directly in `infrastructure/modules/verify_access/main.tf`. The four image tags in use are:
- `icr.io/ivia/ivia-config:11.0.2.0`
- `icr.io/ivia/ivia-runtime:11.0.2.0`
- `icr.io/ivia/ivia-wrp:11.0.2.0`
- `icr.io/ivia/ivia-oidc-provider:25.10`
:::
