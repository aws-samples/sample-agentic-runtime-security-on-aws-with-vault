# IVIA Stack — Redeploy & Troubleshooting Runbook

Definitive playbook for tearing down and redeploying the IBM Verify Identity Access (IVIA) stack on EKS.

---

## Quick Reference

| Component | Terraform Resource | Image | Port |
|-----------|-------------------|-------|------|
| OIDC Provider | `kubernetes_deployment.isvaop` | `icr.io/ivia/ivia-oidc-provider:25.10` | 8436 |
| Config + slapd + Runtime | `kubernetes_deployment.ivia_config` | `ivia-config:11.0.2.0` + `slapd` + `ivia-runtime:11.0.2.0` | 9443, 389, 9444 |
| Web Reverse Proxy | `kubernetes_deployment.ivia_wrp` | `icr.io/ivia/ivia-wrp:11.0.2.0` | 9443 |
| WRP Service | `kubernetes_service.ivia_wrp` | — | 9443 (ClusterIP) |
| WRP Ingress (ALB) | `kubernetes_ingress_v1.ivia_wrp` | — | 80 (HTTP) → 9443 (HTTPS) |
| DB Init Job | `kubernetes_job.ivia_db_init` | `postgres:17-alpine` | — |
| Autoconf Job | `kubernetes_job.ivia_autoconf` | `curlimages/curl:latest` | — |

**Namespace:** `verify-access`
**Terraform module:** `module.ivia` (source: `./modules/verify_access`)
**State:** local (`infrastructure/terraform.tfstate`)

---

## 1. Assess Current State

```bash
kubectl get pods -n verify-access -o wide
kubectl get events -n verify-access --sort-by='.lastTimestamp' | tail -20
kubectl get pvc -n verify-access
kubectl get svc -n verify-access
kubectl get ingress -n verify-access

# Container logs (Config pod has 3 containers)
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-config -c ivia-config --tail=50
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-config -c slapd --tail=50
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-config -c ivia-runtime --tail=50
kubectl logs -n verify-access -l app.kubernetes.io/name=isvaop --tail=50
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-wrp --tail=50
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf --tail=100
```

---

## 2. Open Monitoring Shells (do this first)

Before running any destroy or apply, open dedicated terminal tabs/panes to watch pod lifecycle in real time. These stay open throughout the entire workflow so you see every transition as it happens.

**Shell 1 — Pod watch (always open)**
```bash
kubectl get pods -n verify-access -w
```

**Shell 2 — Events stream**
```bash
kubectl get events -n verify-access --watch-only
```

**Shell 3 — Config pod logs (LMI + slapd + runtime)**
```bash
# This will reconnect automatically as the pod restarts
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-config -c ivia-config -f --tail=50 2>/dev/null; \
  echo "--- config container exited, waiting for restart ---"; sleep 5; \
  kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-config -c ivia-config -f --tail=50
```

**Shell 4 — Autoconf job logs (start after apply)**
```bash
# Run this after terraform apply — the job won't exist until then
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf -f --tail=200
```

**Shell 5 — WRP logs**
```bash
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-wrp -f --tail=50
```

> **Why parallel shells matter:** The IVIA stack has cascading startup dependencies — Config must be ready before autoconf runs, autoconf must complete before WRP starts, and each autoconf deploy step restarts the LMI causing temporary pod-not-ready transitions. Without parallel monitoring you'll miss transient errors that explain why a downstream component failed. Report what you see in each shell as things happen — timestamps in the event stream correlate directly with autoconf step progression.

---

## 3. Unlock Terraform State (if locked)

If a previous apply was interrupted, state will be locked:

```bash
cd infrastructure

# The error message includes the Lock ID:
terraform force-unlock <LOCK_ID>
```

State is stored locally (`infrastructure/terraform.tfstate`). If the lock file is stale, you can also delete `.terraform.tfstate.lock.info` directly.

---

## 3. Terraform Destroy (Primary Path)

```bash
cd infrastructure

# Destroy only the IVIA module — leaves EKS, RDS, Vault, etc. intact
terraform destroy -target=module.ivia -auto-approve
```

**MANDATORY post-destroy verification — confirm PVCs are gone BEFORE re-applying:**

```bash
kubectl get pvc -n verify-access            # Expect: "No resources found"
kubectl get ns verify-access                # Expect: "NotFound"
kubectl get pv | grep -E "verify-access|iviaconfig|ldap"   # Expect: empty
```

If any of these still show resources, the destroy is incomplete — **do NOT proceed to apply**. The four PVCs (`iviaconfig`, `ldapslapd`, `ldapsecauthority`, `ldaplib`) MUST all be gone. If `secAuthority=Default` survives on the OpenLDAP PVC (`ldapsecauthority` / `ldapslapd` / `ldaplib`), the next autoconf will fail with `DPWAP0003I "A policy server is already configured to this LDAP server"` and the WRP will never create `rp1` (`WGAWA0963E rp1 is not a known instance`).

This cleanly removes all IVIA resources from EKS and Terraform state:

| Category | Resources Destroyed |
|----------|-------------------|
| **Deployments** | `isvaop`, `ivia-config` (3-container: config+slapd+runtime), `ivia-wrp` |
| **Jobs** | `ivia-db-init`, `ivia-autoconf` |
| **Services** | `isvaop` (:8436), `iviaconfig` (:9443), `iviaruntime` (:9443), `iviawrp` (:9443) |
| **Ingress** | `ivia-wrp` (ALB, internet-facing) |
| **PVC** | `ivia-config-pvc` (1Gi gp2 — Config container state) |
| **Secrets** | `icr-pull-secret`, `isvaop-server`, `isvaop-obf`, `isvaop-ldap`, `ivia-admin`, `ivia-configreader`, `ivia-hvdb-creds` |
| **ConfigMaps** | `isvaop-cfg-data`, `ivia-hvdb-schema`, `ivia-config-ds`, `ivia-runtime-port-override`, `ivia-autoconf-config` |
| **Network Policies** | `ivia-default-deny`, `ivia-allow-dns`, `ivia-config-allow-inbound`, `ivia-wrp-allow-ingress`, `ivia-wrp-allow-egress`, `ivia-runtime-allow-inbound`, `ivia-runtime-allow-egress`, `isvaop-allow-inbound`, `isvaop-allow-egress` |
| **RBAC** | `isvaop` ServiceAccount, Role, RoleBinding |
| **Namespace** | `verify-access` |
| **TLS/Crypto** | Self-signed cert + private key (Terraform-internal, not K8s resources) |
| **Passwords** | `obfuscation_key`, `client_secret`, `ivia_admin_pwd`, `ivia_hvdb_pwd`, `configreader_pwd` (random_password resources — regenerated on next apply) |

### 3a. Wipe the PVC (if destroy didn't delete it, or you need a clean config DB)

The Config container persists its internal database on the PVC. Stale LDAP ports, expired trial state, or corrupted config snapshots survive a normal pod restart. After destroy, the PVC should be gone — but verify:

```bash
kubectl get pvc -n verify-access
# If ivia-config-pvc still exists:
kubectl delete pvc ivia-config-pvc -n verify-access --ignore-not-found
```

> **When to wipe PVC:** Always wipe if you see WGAWA0260E, DPWAP0010E, HPDCO0192W, or pdmgrd flapping. The PVC carries config DB state that cannot be updated via API — only a fresh bootstrap fixes it.

---

## 4. Fallback — Manual Cleanup (when `terraform destroy` fails)

Only needed when the Kubernetes provider errors out (e.g., "Unexpected Identity Change", "object has been deleted", provider panic). Two steps: delete the K8s resources, then clean state.

### 4a. Delete K8s Resources

```bash
# Deployments
kubectl delete deployment ivia-wrp ivia-config isvaop -n verify-access --ignore-not-found

# Jobs
kubectl delete job ivia-autoconf ivia-db-init -n verify-access --ignore-not-found

# Services
kubectl delete service iviawrp iviaconfig iviaruntime isvaop -n verify-access --ignore-not-found

# Ingress
kubectl delete ingress ivia-wrp -n verify-access --ignore-not-found

# PVC (wipes config DB)
kubectl delete pvc ivia-config-pvc -n verify-access --ignore-not-found

# Secrets
kubectl delete secret icr-pull-secret isvaop-server isvaop-obf isvaop-ldap \
  ivia-admin ivia-configreader ivia-hvdb-creds -n verify-access --ignore-not-found

# ConfigMaps
kubectl delete configmap isvaop-cfg-data ivia-hvdb-schema ivia-config-ds \
  ivia-runtime-port-override ivia-autoconf-config -n verify-access --ignore-not-found

# Network Policies
kubectl delete networkpolicy ivia-default-deny ivia-allow-dns ivia-config-allow-inbound \
  ivia-wrp-allow-ingress ivia-wrp-allow-egress ivia-runtime-allow-inbound \
  ivia-runtime-allow-egress isvaop-allow-inbound isvaop-allow-egress -n verify-access --ignore-not-found
```

Or nuke the entire namespace:

```bash
kubectl delete namespace verify-access --ignore-not-found
kubectl wait --for=delete namespace/verify-access --timeout=120s 2>/dev/null || true
```

### 4b. Clean Terraform State

```bash
cd infrastructure

# Remove all IVIA resources from state
terraform state list | grep 'module.ivia' | while read resource; do
  terraform state rm "$resource"
done
```

---

## 5. Redeploy

**Two-step apply** — first `-target=module.ivia` to bring up IVIA, then a full `terraform apply` to patch the OIDC issuer to the real ELB hostname and reconcile dependents (banking-ui, uc3-agent, route53 record).

> **Why two steps?** `terraform apply -target=module.ivia` brings up the IVIA stack but the OIDC discovery document serves the placeholder issuer `https://issuer-patched-at-root.invalid`. That's because `kubernetes_config_map_v1_data.iviaop_clients_patch` (in root `main.tf`, NOT in `module.ivia`) is the resource that overwrites the placeholder with the real WRP ALB hostname (only known after `module.ivia` creates the Ingress). A second, full `terraform apply` runs this patch + restarts iviaop to re-read clients.yml + recreates any banking/uc3 dependents that were destroyed alongside `module.ivia`.

> **Why `-target=module.ivia` for the first step?** All IVIA applies MUST use `-target=module.ivia`. A full `terraform apply` fails with "Kubernetes cluster unreachable" because the Kubernetes and Helm providers depend on `data.aws_eks_cluster.this`, which has `depends_on = [module.eks]` (providers.tf line 84). Terraform defers reading that data source until apply time — even when the cluster already exists — so the providers get empty config during the plan phase. Targeting `module.ivia` avoids re-evaluating `module.eks`, letting the data source resolve immediately from state. The second-step full `terraform apply` works because the prior targeted apply has already primed the data source.

### Step 1 — Bring up IVIA

```bash
cd infrastructure
terraform apply -target=module.ivia -auto-approve
```

The autoconf Job runs 18 steps in strict sequence:

```bash
# Monitor in Shell 4 (from Section 2)
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf -f --tail=200
```

Steps: (1) wait LMI → (2) accept SLA → (3) trial verify → (4) HVDB → (5) deploy → (6) re-wait → (7) clean dirs → (8) runtime config → (9) deploy → (10) re-wait → (11) Simple AD feddir → (12) deploy → (13) WRP create → (14) deploy → (15) junction /isvaop → (16) anyauth ACL → (17) cfgsvc pwd → (18) final deploy

### Step 2 — Patch the issuer + reconcile dependents (full apply)

After step 1 completes, the OIDC discovery document at `/isvaop/oauth2/.well-known/openid-configuration` still serves the placeholder issuer `https://issuer-patched-at-root.invalid` — sign-in flows will not work until this is patched. Run a full apply to overwrite the placeholder, restart iviaop, and recreate banking-ui + uc3-agent:

```bash
terraform apply -auto-approve
```

Confirm the issuer is now the real ELB hostname:

```bash
kubectl -n verify-access exec deploy/iviawrprp1 -- \
  curl -sk https://localhost:9443/isvaop/oauth2/.well-known/openid-configuration \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("issuer:", d["issuer"])'
# Expect: issuer: https://k8s-verifyac-iviawrp-<id>.<region>.elb.amazonaws.com
# (NOT https://issuer-patched-at-root.invalid)
```

### Verify base components

```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ivia-config -n verify-access --timeout=300s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=isvaop -n verify-access --timeout=180s
kubectl exec -n verify-access deploy/iviaconfig -- curl -sk -o /dev/null -w '%{http_code}' https://localhost:9443/core/login
```

### Verify WRP + OIDC

```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ivia-wrp -n verify-access --timeout=300s

WRP_HOST=$(kubectl get ingress -n verify-access ivia-wrp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$WRP_HOST/isvaop/oauth2/.well-known/openid-configuration" | jq .issuer
```

---

## 6. Full Apply (All Modules)

```bash
cd infrastructure
terraform apply -auto-approve
```

Deploys in dependency order: EKS → Addons → RDS → Vault → Simple AD → IVIA → Vault Config → UC agents.

---

## 7. Gradual Startup Behavior (Do NOT Panic)

The IVIA stack comes up **gradually** over 10-15 minutes. Transient errors during this period are normal and self-resolve as components initialize in sequence. Do not intervene manually — let the autoconf retries handle it.

**Expected startup timeline:**

| Time after apply | What's happening | What you'll see |
|-----------------|-----------------|-----------------|
| 0-2 min | Config (LMI) starts, slapd starts | `ivia-config` 2/3 Ready (runtime CrashLoopBackOff) |
| 2-5 min | Autoconf Steps 1-6: SLA, trial check, HVDB, deploy | LMI restarts after HVDB deploy |
| 5-8 min | Autoconf Steps 7-10: Runtime config, cfgsvc, deploy | Runtime downloads snapshot, pdmgrd initializing |
| 8-12 min | Autoconf Step 13: WRP create | **DPWAP0010E is expected here** — pdmgrd not ready yet. Autoconf retries every 30s (10 attempts). |
| 10-15 min | pdmgrd stabilizes, WRP creates, junction + ACL | All steps complete |
| 15+ min | WRP pod starts, downloads snapshot | Full stack healthy |

**Key insight:** The runtime container may show as Running but pdmgrd (the policy server process inside it) takes additional time to initialize after receiving its configuration snapshot. Step 13 (WRP create) requires pdmgrd to be accepting connections. The `DPWAP0010E` error during this window is **not a failure** — it means pdmgrd hasn't finished starting. The autoconf's 10-attempt retry loop (30s intervals = 5 min window) exists specifically for this reason.

**Cross-cycle convergence:** The autoconf job has a backoff limit of 10 retries. If WRP create exhausts all 10 attempts in one cycle, the job exits with error and Kubernetes restarts it. On the next cycle, the runtime container has had more time with the configuration snapshot from the previous cycle's deploys — pdmgrd gets closer to ready with each pass. The config pod will show 3/3 Running even while the autoconf is retrying. This is normal convergence behavior — the system self-heals across autoconf cycles without intervention.

**When to actually worry:**
- Autoconf exhausts its backoff limit (10 job restarts, not just 10 WRP attempts) and enters `Failed` state
- Runtime container keeps CrashLoopBackOff after autoconf Steps 8-9 complete across multiple cycles
- Config container itself never reaches Ready (LMI not responding)

---

## 8. Common Failures

| Error | Root Cause | Fix |
|-------|-----------|-----|
| **WGAWA0260E** "Runtime not configured" | PVC has stale state; pdconfig/ivmgrd not running | Destroy, wipe PVC, redeploy |
| **DPWAP0010E** "Failed to establish secure connection to policy server" | pdmgrd not yet ready OR port collision OR stale LDAP | **During autoconf Step 13: wait for retries.** If persistent after all retries: verify runtime on 9444 not 9443; verify `dc=iswga` in LDAP; wipe PVC if flapping |
| **HPDCO0192W** "LDAP server 127.0.0.1:9389 has failed" | PVC remembers wrong LDAP port from previous deploy | Wipe PVC, redeploy — slapd must be on 389 |
| **CrashLoopBackOff** on ivia-runtime | **Expected on fresh PVC** — no snapshot yet | Wait for autoconf Steps 8-9 to complete |
| **ImagePullBackOff** | Expired or invalid ICR entitlement key | Update `icr_entitlement_key` in terraform.tfvars |
| **HTTP 302** on trial activation API | API doesn't work on IVIA 11.0.2.0 | Use LMI UI (Section 5c) |
| **Unexpected Identity Change** | Kubernetes provider bug — UID changed | `terraform state rm` the resource, then re-apply |

---

## 8. Diagnostic Cheat Sheet

```bash
# Process checks — pdmgrd does NOT show in `ps aux | grep pdmgrd`.
# It runs as a native process under a different name. Check port 7135 instead:
kubectl exec -n verify-access deploy/ivia-config -c ivia-runtime -- netstat -tlnp 2>/dev/null || \
  kubectl exec -n verify-access deploy/ivia-config -c ivia-runtime -- cat /proc/net/tcp6
# Port 7135 = pdmgrd (policy server), 9389 = IVIA LDAP proxy, 9636 = IVIA LDAPS proxy
# Port 9444 = Liberty (runtime), 389 = slapd, 636 = slapd TLS

kubectl exec -n verify-access deploy/ivia-config -c slapd -- ps aux | grep slapd

# LDAP — dc=iswga must exist
kubectl exec -n verify-access deploy/ivia-config -c slapd -- \
  ldapsearch -x -H ldap://localhost:389 -b "dc=iswga" -s base

# Port check — runtime MUST be 9444, NOT 9443
kubectl exec -n verify-access deploy/ivia-config -c ivia-runtime -- ss -tlnp | grep -E '9443|9444'

# LMI API (substitute actual admin password)
ADMIN_PWD=$(kubectl get secret ivia-admin -n verify-access -o jsonpath='{.data.admin_password}' | base64 -d)

# HVDB status (~101 tables)
kubectl exec -n verify-access deploy/ivia-config -c ivia-config -- \
  curl -sk -u "admin:$ADMIN_PWD" https://localhost:9443/isam/cluster/v2

# Runtime config
kubectl exec -n verify-access deploy/ivia-config -c ivia-config -- \
  curl -sk -u "admin:$ADMIN_PWD" https://localhost:9443/isam/runtime_components

# WRP instances
kubectl exec -n verify-access deploy/ivia-config -c ivia-config -- \
  curl -sk -u "admin:$ADMIN_PWD" https://localhost:9443/wga/reverseproxy

# OIDC discovery (internal)
kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never -n verify-access -- \
  curl -sk https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration | jq .
```

---

## 9. Architecture Notes

**3-Container Pod:** Config deployment runs `ivia-config` (LMI, 9443) + `slapd` (embedded OpenLDAP, 389) + `ivia-runtime` (AAC, 9444) in one pod. Required because AWS Simple AD lacks IBM schema extensions (`secAuthority=Default`); the embedded slapd provides them. pdconfig binds to `localhost:389` so slapd must be co-located. Runtime overridden to 9444 to avoid LMI port collision.

**Autoconf ordering:** Trial (Step 3) gates everything → HVDB (4) before Runtime (8) → Runtime (8) before WRP (13). Each deploy step restarts LMI, requiring re-wait + re-accept SLA.

**`var.ivia_activated` gating mechanism:** The variable uses `count = var.ivia_activated ? 1 : 0` on exactly two resources: `kubernetes_job.ivia_autoconf` (main.tf ~line 1951) and `kubernetes_deployment.ivia_wrp` (main.tf ~line 2344). All other IVIA resources — including the WRP Service (`kubernetes_service.ivia_wrp`) and WRP Ingress/ALB (`kubernetes_ingress_v1.ivia_wrp`) — deploy unconditionally in Phase 1. The ALB exists during Phase 1 but returns HTTP 502 (no healthy targets) until Phase 2 brings up the WRP pods. This is harmless; the ALB is pre-provisioned so Phase 2 only needs to start the WRP deployment and autoconf job. The variable is set in `infrastructure/terraform.tfvars` and passed through `infrastructure/main.tf` → `module.ivia` → `modules/verify_access/variables.tf`.

**Dependent modules:** `module.uc2_agent` and `module.uc3_agent` consume IVIA outputs (ingress hostname, service endpoint, client secret). Vault jwt auth consumes OIDC discovery URL + JWKS + TLS cert.
