# IVIA Stack — Redeploy & Troubleshooting Runbook

Definitive playbook for tearing down and redeploying the IBM Verify Identity Access (IVIA) stack on EKS.

---

## Quick Reference

| Component | Deployment | Image | Port | Gated by `ivia_activated` |
|-----------|-----------|-------|------|---------------------------|
| OIDC Provider | `isvaop` | `icr.io/ivia/ivia-oidc-provider:25.10` | 8436 | No |
| Config + slapd + Runtime | `ivia-config` | `ivia-config:11.0.2.0` + `slapd` + `ivia-runtime:11.0.2.0` | 9443, 389, 9444 | No |
| Web Reverse Proxy | `ivia-wrp` | `icr.io/ivia/ivia-wrp:11.0.2.0` | 9443 | **Yes** |
| DB Init Job | `ivia-db-init` | `postgres:17-alpine` | — | No |
| Autoconf Job | `ivia-autoconf` | `curlimages/curl:latest` | — | **Yes** |

**Namespace:** `verify-access`
**Terraform module:** `module.ivia` (source: `./modules/verify_access`)
**HCP Terraform workspace:** `agentic-runtime-security`

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

**Shell 5 — WRP logs (start after ivia_activated=true apply)**
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
TF_CLOUD_ORGANIZATION=devopsoscar terraform force-unlock <LOCK_ID>
```

If CLI unlock fails, go to https://app.terraform.io → workspace `agentic-runtime-security` → Settings → Locking → Force Unlock.

---

## 3. Terraform Destroy (Primary Path)

```bash
cd infrastructure

# Destroy only the IVIA module — leaves EKS, RDS, Vault, etc. intact
TF_CLOUD_ORGANIZATION=devopsoscar terraform destroy -target=module.ivia -auto-approve
```

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
TF_CLOUD_ORGANIZATION=devopsoscar terraform state list | grep 'module.ivia' | while read resource; do
  TF_CLOUD_ORGANIZATION=devopsoscar terraform state rm "$resource"
done
```

---

## 5. Redeploy (Two-Phase Apply)

The redeploy is a **two-phase terraform apply** with a manual UI step in between:

| Phase | `ivia_activated` | What deploys | What's manual |
|-------|-----------------|-------------|---------------|
| **Phase 1** | `false` (default) | Config+slapd+Runtime pod, OIDC Provider, DB init job, secrets, configmaps, network policies, namespace | — |
| **Manual gate** | — | — | Accept SLA, login to LMI, import trial license |
| **Phase 2** | `true` | WRP deployment, autoconf job, WRP ingress (ALB) | — |

> **Why two phases?** The WRP and autoconf job require the trial license to be active (wga, mga, federation modules). On a fresh PVC, all three API methods for trial activation fail (HTTP 302). The only proven path is the LMI browser UI. Phase 1 brings the LMI up so you can activate the trial; Phase 2 deploys everything that depends on it.

---

### Phase 1 — Deploy Base Components

**First, ensure `ivia_activated = false` in `terraform.tfvars`:**

```bash
cd infrastructure

# Set ivia_activated to false for Phase 1
sed -i '' 's/^ivia_activated = true/ivia_activated = false/' terraform.tfvars

# Verify
grep ivia_activated terraform.tfvars
# Expected: ivia_activated = false
```

Then apply:

```bash
TF_CLOUD_ORGANIZATION=devopsoscar terraform apply -target=module.ivia -auto-approve
```

Verify base components are healthy:

```bash
# Config pod (3 containers: ivia-config, slapd, ivia-runtime)
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ivia-config -n verify-access --timeout=300s

# slapd on port 389
kubectl exec -n verify-access deploy/ivia-config -c slapd -- ss -tlnp | grep 389

# LMI responding (expect HTTP 200)
kubectl exec -n verify-access deploy/ivia-config -c ivia-config -- \
  curl -sk -o /dev/null -w '%{http_code}' https://localhost:9443/core/login

# Runtime on port 9444 (NOT 9443 — avoids LMI collision)
kubectl exec -n verify-access deploy/ivia-config -c ivia-runtime -- ss -tlnp | grep 9444

# OIDC Provider
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=isvaop -n verify-access --timeout=180s
```

---

### Manual Gate — LMI Admin Setup + Trial Activation

> **This blocks Phase 2.** The autoconf job (Phase 2) attempts trial activation via API, but all three methods historically fail on a fresh PVC. You must do this manually via the LMI browser UI.

**Get credentials and port-forward:**

```bash
# Admin password (Terraform-generated, random 24 chars)
kubectl get secret ivia-admin -n verify-access -o jsonpath='{.data.admin_password}' | base64 -d; echo

# Port-forward to LMI (keep this shell open)
kubectl port-forward -n verify-access svc/iviaconfig 9443:9443
```

**In the browser:**

1. Open **https://localhost:9443** — accept the self-signed certificate
2. **Accept the SLA** — this is the first screen the LMI shows on a fresh PVC
3. **Login** — username `admin`, password from the command above
4. If prompted to change the admin password:
   - Set it to something memorable (e.g., `theace01`)
   - Then update the K8s secret so autoconf can authenticate:
     ```bash
     kubectl patch secret ivia-admin -n verify-access \
       -p='{"stringData":{"admin_password":"<your-new-password>"}}'
     ```
5. Navigate to **System > Trial > Import**
6. Upload `ISAM-Trial-HashiCorp.cer` (located in `infrastructure/`)
7. Click **Save Configuration** — wait ~10s for reload
8. Go back to **System > Trial** — confirm three modules activated:
   - **wga** (Web Gateway / Reverse Proxy)
   - **mga** (Mobile Gateway / Advanced Access Control)
   - **federation** (OIDC / SAML / Token Exchange)
9. Note the expiration date (84 days from activation)

> If modules don't appear, the trial cert may be expired. Get a new one from https://isva-trial.verify.ibm.com/ and repeat steps 5-8.

Close the port-forward when done. Autoconf uses the internal ClusterIP service.

---

### Phase 2 — Deploy Gated Resources

**Flip `ivia_activated` to `true` in `terraform.tfvars`:**

```bash
cd infrastructure

# Set ivia_activated to true for Phase 2
sed -i '' 's/^ivia_activated = false/ivia_activated = true/' terraform.tfvars

# Verify
grep ivia_activated terraform.tfvars
# Expected: ivia_activated = true
```

Then apply:

```bash
TF_CLOUD_ORGANIZATION=devopsoscar terraform apply -target=module.ivia -auto-approve
```

This deploys the **WRP**, **autoconf job**, and **ALB ingress**. The autoconf job runs 18 steps in strict sequence:

```bash
# Monitor in Shell 4 (from Section 2)
kubectl logs -n verify-access -l app.kubernetes.io/name=ivia-autoconf -f --tail=200
```

Steps: (1) wait LMI → (2) accept SLA → (3) trial verify → (4) HVDB → (5) deploy → (6) re-wait → (7) clean dirs → (8) runtime config → (9) deploy → (10) re-wait → (11) Simple AD feddir → (12) deploy → (13) WRP create → (14) deploy → (15) junction /isvaop → (16) anyauth ACL → (17) cfgsvc pwd → (18) final deploy

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
TF_CLOUD_ORGANIZATION=devopsoscar terraform apply -auto-approve
```

Deploys in dependency order: EKS → Addons → RDS → Vault → Simple AD → IVIA → Vault Config → UC agents.

---

## 7. Common Failures

| Error | Root Cause | Fix |
|-------|-----------|-----|
| **WGAWA0260E** "Runtime not configured" | PVC has stale state; pdconfig/ivmgrd not running | Destroy, wipe PVC, redeploy |
| **DPWAP0010E** "Failed to establish secure connection to policy server" | pdmgrd flapping; port collision or stale LDAP config | Verify runtime on 9444 not 9443; verify `dc=iswga` in LDAP; wipe PVC if flapping |
| **HPDCO0192W** "LDAP server 127.0.0.1:9389 has failed" | PVC remembers wrong LDAP port from previous deploy | Wipe PVC, redeploy — slapd must be on 389 |
| **CrashLoopBackOff** on ivia-runtime | **Expected on fresh PVC** — no snapshot yet | Wait for autoconf Steps 8-9 to complete |
| **ImagePullBackOff** | Expired or invalid ICR entitlement key | Update `icr_entitlement_key` in HCP variable set |
| **HTTP 302** on trial activation API | API doesn't work on IVIA 11.0.2.0 | Use LMI UI (Section 5c) |
| **Unexpected Identity Change** | Kubernetes provider bug — UID changed | `terraform state rm` the resource, then re-apply |

---

## 8. Diagnostic Cheat Sheet

```bash
# Process checks
kubectl exec -n verify-access deploy/ivia-config -c ivia-config -- ps aux | grep pdmgrd
kubectl exec -n verify-access deploy/ivia-config -c ivia-config -- ps aux | grep ivmgrd
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

**Dependent modules:** `module.uc2_agent` and `module.uc3_agent` consume IVIA outputs (ingress hostname, service endpoint, client secret). Vault jwt auth consumes OIDC discovery URL + JWKS + TLS cert.
