# verify_access — IBM Verify Identity Access (IVIA) Module

Phase 7 (May 2026) replacement of the legacy 3241-line single-pod-sidecar
module. Implements the sibling-repo `verify-access-container-deployment`
proven happy path against EKS:

- 7 deployments in single `verify-access` namespace.
- Pinned image tags — see Pinned Versions below.
- In-cluster `kubernetes_job_v1` running `python -m ibmvia_autoconf 0.3.34`
  against a MINIMAL `webseal.runtime` base_layer.yaml.
- LMI external exposure via NLB Service (TCP passthrough on 9443) for
  `isva_config` Mastercard/restapi provider consumption.
- WRP browser exposure via existing ALB Ingress.
- HVDB hosted in a dedicated `postgresql` pod (NOT shared RDS).

## Pinned versions (do not change without re-validating against sibling)

| Component | Image | Tag |
|---|---|---|
| LMI / DSC / Runtime / WRP / Postgres | `icr.io/ivia/ivia-{config,dsc,runtime,wrp,postgresql}` | `11.0.2.0` |
| OIDC Provider | `icr.io/ivia/ivia-oidc-provider` | `25.10` |
| OpenLDAP | `icr.io/isva/verify-access-openldap` | `10.0.6.0` |
| autoconf SDK | `ibmvia_autoconf` (pip) | `0.3.34` |
| autoconf SDK dep | `pyivia` (pip) | `0.2.44` |
| Job init container | `busybox` | `1.36` |
| Job main container | `python` | `3.11-slim` |

## Architecture

Pods:
- `openldap` — LDAP backend for `secAuthority=Default` + `dc=ibm,dc=com`.
- `postgresql` — HVDB (runtime DB, sessions, cluster DB). UID 26/26
  (upstream's 70/85 is wrong for the 11.0.2.0 image).
- `iviaconfig` — LMI on :9443.
- `iviadsc` — Distributed Session Cache. Service selector LOCKED to
  `app: iviadsc` (upstream typo `isvadsc` carried as sibling fix).
- `iviaop` — OAuth/OIDC token endpoint on :8436. Behind WRP `/isvaop`.
- `iviaruntime` — AAC runtime.
- `iviawrprp1` — Web Reverse Proxy `rp1`, browser-facing on :9443.

PVCs (5, all gp2 RWO 50M):
`ldaplib`, `ldapslapd`, `ldapsecauthority` (openldap), `postgresqldata`
(postgresql), `iviaconfig` (LMI).

Services:
- ClusterIP per pod (in-cluster traffic).
- `iviaconfig-nlb` LoadBalancer (NLB, internet-facing, TCP passthrough
  on 9443 — for `isva_config` REST API reachability).
- `ivia-wrp` Ingress (ALB, HTTP listener → HTTPS:9443 backend — for
  browser-facing CIBA flows).

## Inputs

| Variable | Purpose |
|---|---|
| `region` | AWS region (tagging) |
| `cluster_name` | EKS cluster name (tagging) |
| `icr_entitlement_key` | ICR pull credential (builds `dockerlogin` Secret) |
| `node_security_group_id` | EKS node SG (target for cross-node TCP/636 rule) |
| `lmi_allowed_cidrs` | CIDR allowlist for inbound NLB :9443. Default `["0.0.0.0/0"]`. |
| `tags` | AWS resource tags |

## Outputs

| Output | Purpose |
|---|---|
| `namespace` | `verify-access` |
| `ivia_lmi_nlb_hostname` | NLB hostname for `isva_config.ivia_service_endpoint` |
| `ivia_wrp_alb_hostname` | ALB hostname for browser flows |
| `ivia_admin_password` | Generated LMI admin password (sensitive) |
| `ivia_nlb_ready` | 90s `time_sleep` gate to mitigate empty-hostname race |

## Apply

```bash
cd infrastructure
terraform apply -target=module.ivia
# ~12-15 min for image pulls + ~5-10 min for autoconf Job
kubectl rollout restart deploy/iviawrprp1 -n verify-access  # required post-step
bash scripts/ivia-configure.sh  # exit gate
```

The exit gate verifies the OIDC discovery endpoint via the WRP:

```bash
kubectl exec -n verify-access deploy/iviawrprp1 -- \
  curl -sk https://localhost:9443/isvaop/oauth2/.well-known/openid-configuration \
  | jq '{issuer, backchannel_authentication_endpoint, pushed_authorization_request_endpoint, registration_endpoint}'
```

All four fields MUST be non-null.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 8× `HPDRG0201E "Already exists"`, no rp1 | `suffix:` or `override_config:` in `webseal.runtime` | Keep `webseal.runtime` MINIMAL. NEVER add these keys. (RESEARCH Pitfall 2) |
| `RuntimeError: Namespace file ... not found` | Autoconf running outside a pod | Should not happen — Job is in-cluster. If it does, check ServiceAccount mount. (RESEARCH Pitfall 1) |
| `iviadsc Service has no endpoints` | Selector typo `app: isvadsc` vs pod label `app: iviadsc` | Verify `kubernetes_service.iviadsc` selector is `{ app = "iviadsc" }`. (RESEARCH Pitfall 5) |
| `postgresql CrashLoopBackOff: cannot find name for user ID 70` | securityContext mis-set | `runAsUser=26 fsGroup=26` (NOT upstream's 70/85). (RESEARCH Pitfall 4) |
| WRP returns 502 / `WGAWA0963E` for minutes after autoconf | Stale snapshot backoff | `kubectl rollout restart deploy/iviawrprp1 -n verify-access`. (RESEARCH Pitfall 6) |
| cert/lua `Failed to upload … already exists` in Job logs | Cert imports + lua transforms are not idempotent | Expected on re-runs. Non-fatal; cross-cycle convergence. (RESEARCH Pitfall 3) |
| First `terraform apply` fails because `isva_config` can't resolve NLB | NLB hostname empty on first apply | Re-run apply; the `time_sleep.ivia_nlb_ready` (90s) usually clears it. |

## Phase 7 plan references

- `.planning/phases/07-ivia-deployment-refactor/07-CONTEXT.md` — 21 locked decisions.
- `.planning/phases/07-ivia-deployment-refactor/07-RESEARCH.md` — ~1700-line technical reference.
- `.planning/phases/07-ivia-deployment-refactor/07-10-VERIFICATION.md` — this plan's smoke-test runbook.
- Sibling working artifacts: `~/git-repos/verify-access-container-deployment/`.
