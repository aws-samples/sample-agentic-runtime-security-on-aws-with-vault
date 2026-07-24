# verify_access — IBM Verify Identity Access (IVIA) Module

Phase 7 (May 2026) replacement of the legacy 3241-line single-pod-sidecar
module. Implements the sibling-repo `verify-access-container-deployment`
proven happy path against EKS:

- 7 deployments in single `verify-access` namespace.
- Pinned image tags — see Pinned Versions below.
- In-cluster `kubernetes_job_v1` running `python -m ibmvia_autoconf 0.3.21`
  against a MINIMAL `webseal.runtime` base_layer.yaml.
- LMI is NOT exposed externally. Admin-only, one-time bring-up via
  `kubectl port-forward svc/iviaconfig 9443:9443` (4 manual browser steps).
- `isva_config` reaches LMI via in-cluster DNS (`iviaconfig.verify-access.svc.cluster.local:9443`).
- WRP browser exposure via ALB Ingress (the OIDC/UC entry point).
- HVDB hosted in a dedicated `postgresql` pod (NOT shared RDS).

## Pinned versions (do not change without re-validating against sibling)

| Component | Image | Tag |
|---|---|---|
| LMI / DSC / Runtime / WRP / Postgres | `icr.io/ivia/ivia-{config,dsc,runtime,wrp,postgresql}` | `11.0.2.0` |
| OIDC Provider | `icr.io/ivia/ivia-oidc-provider` | `25.10` |
| OpenLDAP | `icr.io/isva/verify-access-openldap` | `10.0.6.0` |
| autoconf SDK | `ibmvia_autoconf` (pip) | `0.3.21` (installed `--no-deps`) |
| autoconf SDK dep | `pyivia` (pip) | `0.2.44` |
| autoconf SDK dep | `pyyaml` (pip) | `6.0.1` |
| Job init container | `busybox` | `1.36` |
| Job main container | `python` | `3.11-slim` |

> **autoconf pinned to 0.3.21, not the sibling's 0.3.34.** From 0.3.22 onward,
> `_configure_api_protection_definition` unconditionally passes the 11.0.3-only
> api_protection kwargs (`definition_id`/`hash_secrets`/`max_active_secrets`/
> `min_secret_len`) to `pyivia create_definition`. On our **11.0.2.0** appliance
> `pyivia` maps to `APIProtection10030`, which lacks those kwargs → `TypeError`
> that blocks MMFA api_protection (and therefore IBM Verify QR enrollment).
> IBM has not shipped an 11.0.3.0 image (icr.io tops out at 11.0.2.0), so the
> appliance cannot be raised to match 0.3.34. 0.3.21 is the last release that
> omits those kwargs and still ships the api_protection/mmfa/push_notifications
> handlers. `pyivia 0.2.44` is unchanged (maps 11.0.2.0 → 10030, compatible).
>
> **Why `--no-deps`.** autoconf 0.3.21 hard-pins `pyyaml==5.4.1` + `Cython<3` in
> its metadata. PyYAML 5.4.1 has no cp311 wheel, so on the `python:3.11-slim`
> Job image pip builds it from sdist — which fails twice (no C compiler in slim;
> and PyYAML 5.4.1's source build breaks against Cython 3). We install autoconf
> `--no-deps` and supply its real runtime imports directly (`pyivia`, `kubernetes`,
> `requests`, `pyyaml==6.0.1`). autoconf only imports `yaml`/`requests`/`pyivia`/
> `kubernetes` (verified in source); `pyyaml 6.0.1` ships a cp311 manylinux wheel
> and is API-compatible (autoconf always calls `yaml.load` with an explicit
> `Loader`). The `Cython`/`docker-compose`/`typing` metadata deps are never
> imported, so they are skipped.

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
- ClusterIP per pod (in-cluster traffic only).
- `ivia-wrp` Ingress (ALB, HTTP listener → HTTPS:9443 backend — for
  browser-facing CIBA flows). This is the ONLY internet-facing IVIA endpoint.

## TLS serving cert ownership (the three IVIA pods)

Authoritative reference for how each IVIA pod's serving TLS cert is produced + installed.
Two of the three pods serve a Terraform-owned cert imported via autoconf; the third
(`iviaruntime`) is the outlier and is the source of the UC3 cert-pinning fragility.

| Pod | Serves on | Cert ownership | Autoconf import mechanism | Stable across pod restart / rebuild? |
| --- | --- | --- | --- | --- |
| `iviaop` (ISVAOP) | :8436 | Terraform-generated keypair `tls_self_signed_cert.iviaop` (RSA 2048, `main.tf`) — public cert in the `iviaop-config` ConfigMap (`iviaop.pem`), private key in the `iviaop-key` **Secret** (`iviaop.key`); both projected into `/var/isvaop/config`. No PEM at rest in git. | `iviaop-config/provider.yml.tftpl` `keystore: isvaop_keys, type: pem` → `'@iviaop.pem'`, `'@iviaop.key'` | **Yes** — state-owned keypair, identical cert every rebuild |
| `iviawrprp1` (WebSEAL) | :443 | Terraform-generated keypair `tls_self_signed_cert.iviawrprp1` (RSA 2048, `main.tf`). The PEM cert+key flow into the base_layer ConfigMap; the autoconf preamble mints `iviawrprp1.p12` in-cluster (sealed with `random_password.wrp_p12_secret`), replacing the committed binary `.p12`. No private key at rest in git. | `base_layer/base_layer.yaml.tftpl` `keystore: pdsrv, personal_certificates: [{name: WRP, p12_file: iviawrprp1.p12}]` (loaded from the deploy-minted p12) | **Yes** — state-owned keypair, identical cert every rebuild |
| `iviaruntime` (AAC runtime, Liberty) | :9443 | Liberty defaultKeyStore auto-self-signs on first start (no Terraform keypair, no PVC) | None — autoconf does NOT install a serving cert into the runtime's defaultKeyStore (the `rt_profile_keys` keystore at `base_layer.yaml.tftpl:27-35` holds only **signer/trust** certs: `postgres.crt`, `DigiCertGlobalRootG3.crt`) | **No** — fresh self-signed cert on every pod restart |

### Why iviaruntime is the outlier

`kubectl get pvc -n verify-access` returns five PVCs: `iviaconfig`, `ldaplib`,
`ldapsecauthority`, `ldapslapd`, `postgresqldata`. **No PVC for `iviaruntime`.** Liberty's
defaultKeyStore therefore lives on the ephemeral container filesystem and is regenerated on
every pod start, producing a fresh self-signed cert (CN=`isam`, no SAN).

### Why this matters — the UC3 refund TLS handshake break

`uc3_agent` pins the iviaruntime cert as its CA: the static file
`iviaop-config/iviaruntime.pem` is read by `outputs.tf` (`ivia_runtime_ca_pem`), feeds
the `ivia-oidc-ca-uc3` Secret in `modules/uc3_agent/main.tf`, mounts at
`/etc/ssl/ivia/iviaruntime.pem`, and is loaded by `app/mmfa.py:_runtime_ssl_context()`
with `check_hostname=False` — so only the cert pin matters. Any `terraform apply` that
restarts iviaruntime regenerates the live serving cert; the pinned file is now stale;
TLS handshake fails `unknown_ca`; `mmfa.fire_push()` silently fails; UC3 refund flow
breaks. Re-capturing the transient cert into git after every restart is a treadmill, not
a fix.

### The durable fix (architectural pattern, not yet implemented)

Bring iviaruntime into the same Terraform-owned + autoconf-installed pattern that already
works for `iviaop` and `iviawrprp1`:

1. Generate the iviaruntime keypair in Terraform via `tls_private_key` +
   `tls_self_signed_cert` (modeled on the existing `tls_self_signed_cert.postgresql` in
   `main.tf` — same module).
2. Mount the new key + cert into the `ivia-base-layer` ConfigMap (alongside the existing
   `iviaop.pem` signer-trust entry).
3. Add an autoconf YAML stanza in `base_layer.yaml.tftpl` to install that keypair into the
   AAC runtime's Liberty defaultKeyStore. **The exact autoconf stanza name for the AAC
   runtime serving keystore is not yet verified** — must be confirmed against
   `pip show ibmvia_autoconf` source + IBM `ibmsecurity` GitHub examples before any YAML
   is written (per project rule: no unverified IBM config keys).
4. `outputs.tf` `ivia_runtime_ca_pem` keeps reading `iviaruntime.pem`, but the file is now
   Terraform-managed and stable across rebuilds. `uc3_agent`'s pin becomes durable.

Same architectural shape as the Vault `bound_issuer` fix (2026-06-03): single source of
truth, both sides reference it, drift becomes impossible by construction.

### Why we don't re-capture the cert manually

Re-capturing `iviaruntime.pem` via `openssl s_client` after every restart was explicitly
rejected as a hack — it requires manual operator action on every IVIA rebuild and is the
same anti-pattern that allowed the Vault `bound_issuer` drift to silently persist. The
durable answer is to make the cert owned by state on one side and installed from state on
the other side, exactly like the other two pods.

## UC3 RAR enforcement model (what Vault enforces vs. what audit correlation proves)

UC3's privileged refund chains RFC 8693 token-exchange with RFC 9396 Rich Authorization
Requests (RAR). The honest, verified security model — recorded here because it shapes any
future decision to switch CIBA providers:

> **Phase 9 — dual RAR emission (`vault:path_access` alongside `refund_approval`).**
> The `isvaop_pretoken` mapping rule (`iviaop-config/rules.yaml`) now stamps **two**
> `authorization_details` entries on the token-exchange output:
> ```json
> "authorization_details": [
>   { "type": "refund_approval" },
>   { "type": "vault:path_access", "path": "database/creds/uc3-refund-writer", "capabilities": ["read"] }
> ]
> ```
> `refund_approval` stays for the business/audit-correlation story (unchanged);
> `vault:path_access` is the **Vault-native per-request RAR** that Vault Enterprise's
> OAuth resource server reads to scope the token to exactly that path + capability for
> that one request. Both types are allowlisted on the ISVAOP client
> (`clients.yml.tftpl` `authorization_details` → `[refund_approval, vault:path_access]`)
> and registered in `provider.yml.tftpl`
> `definition.authorization_details_types_supported`. The rule also stamps a unique
> `jti` (Vault schema-validates it) and `act`/`may_act` = `uc3-actor`. UC2 emits NO
> `vault:path_access` RAR (its registration is `optional_authorization_details=true`).
> With the native cutover, Vault — not IVIA — is the per-request path/action decision
> point; the retired `uc3-jwt` `bound_claims` gate (below) is superseded by the
> agent-registry ceiling ∩ `vault:path_access` model in
> `infrastructure/modules/vault_config/README.md`.

**Vault cryptographically enforces** (the `uc3-jwt` role's `bound_claims` on the exchanged
JWT, in `vault_config`):
- identity — `sub=jaime`, the human who approved via CIBA;
- delegation — `/may_act/sub=uc3-actor` (RFC 8693: WHO may act);
- RAR **type** — `/authorization_details/0/type=refund_approval` (WHAT class of action).

**Audit correlation proves the amount.** Restating the architecture plainly: Vault
cryptographically enforces identity (`sub=jaime`), delegation (`may_act=uc3-actor`), and
RAR type (`refund_approval`). The amount/currency is consent-bound by three-plane audit
correlation on `request_id` — the green 12-column / 0-blank `audit_correlation` row is the
proof that the amount the user approved (e.g. $88.30) is the same amount that hit Vault and
the DB. Vault couldn't numerically enforce an amount anyway (`bound_claims` are string/glob
matches, not range checks), so amount-by-correlation is the correct control, not a
consolation prize.

**Why the amount is not a token claim (verified ISVAOP 25.10, 2026-05-29).** The
consent-time RAR is not exposed to any mapping rule at the CIBA token mint or the
token-exchange stage:
- IBM `tasks-rar`: `authorization_details` is a context attribute only on the request that
  CARRIES it (bc-authorize / authorize); it is returned as a token-RESPONSE field, not a
  JWT claim; `strategy` (sha512) is an identifier hash, not a propagation switch.
- IBM `js_ciba_mapping_rule`: the `ciba` object exposes no `authorization_details` accessor;
  UC3's external check-status authenticator (`ExternalAuthenticatorWithCheckStatusEndpoint`,
  set by the `notifyuser` rule) completes via `ciba.success({sub})`, whose enrichment payload
  carries only the subject — not `authorization_details`.
- Live: jaime's CIBA access token (the token-exchange `subject_token`) decodes with no
  `authorization_details`; the token-exchange pre-token context exposes no such attribute.

So `refund_approval` — the genuine, allowlisted, only RAR type `agent-uc3` can request
(provider `authorization_details_types_supported`) — is what the `isvaop_pretoken` rule
stamps onto the exchanged token (`iviaop-config/rules.yaml`); the amount cannot be made a
Vault-validated claim through documented means. If UC3 later adopts a CIBA provider that
surfaces the consent-time RAR at token mint, the amount could additionally become an
enforced claim; until then this is the documented ceiling for ISVAOP 25.10.

## SCIM bind account — current bind is admin (`cn=root`); `cn=iviascim` least-privilege was reverted

The SCIM service (`access_control.scim`) reads users and reads/writes MMFA transaction
attributes through the `wrp_runtime` LDAP connection. That connection **binds as the ISAM
administrative DN `cn=root,secAuthority=Default`**, using the openldap admin password
(`!secret verify-access/openldap-creds:admin_password`) — see `server_connections.wrp_runtime`
in `base_layer/base_layer.yaml.tftpl` and `local.ivia_scim_bind_dn` in `main.tf`.

**Why admin and not least-privilege.** The
`urn:ietf:params:scim:schemas:extension:isam:1.0:User` schema sets `update_native_users: True`,
so a `/scim/Me` read-back touches native IVIA security-entity data. A least-privilege bind
(`cn=iviascim` was tried) fails the post-PATCH read-back with **HPDAA0319E "insufficient access
rights"**, which blocks MMFA Approve/Deny self-enrollment. IBM's MMFA autoconf reference also
binds `wrp_runtime` as `cn=root,secAuthority=Default`. This is a fixed infrastructure service
principal, not a session-derived identity.

### The `cn=iviascim` account still exists (it is not the bind)

The least-privilege scaffolding is still provisioned, but is **not wired as the SCIM bind**:

- **Generated, never hardcoded.** `random_password.ivia_scim_bind_pwd` (main.tf) mints a
  24-char password at apply time, written to the `ivia-scim-bind` Kubernetes Secret
  (key `bind_pwd`) — no plaintext in code, state-only.
- **Created by autoconf.** The `ibmvia_autoconf` Job creates the `cn=iviascim,dc=ibm,dc=com`
  pdadmin user from that secret (`base_layer.yaml.tftpl`, `webseal.runtime.pdadmin.users`).
- **No effect on the live bind.** Because the active `wrp_runtime` bind is `cn=root` (above),
  **rotating `cn=iviascim` does nothing to the SCIM bind today.** To rotate the credential the
  bind actually uses, rotate the openldap admin password
  (`verify-access/openldap-creds:admin_password`) — which is shared with `webseal.runtime.ldap`
  and the policy-server bind, so the reseed blast radius is larger.

### Future improvement — Vault-managed rotation if least-privilege is re-adopted

If a least-privilege SCIM bind is re-attempted (resolving the HPDAA0319E grant first), put that
account under a Vault `ldap` secrets engine **static role** so Vault owns rotation. The
non-obvious engine topology requirement, verified live 2026-05-30 and confirmed with the
advisor:

- Use a **separate dedicated manager bind account** (e.g. `cn=vault-ldap-manager`) as the
  engine `binddn`, with rights to change the target account's `userPassword`. The static role
  then rotates the target repeatably and exposes the current value via `ldap/static-cred/...`
  for the IVIA reseed.
- **Do NOT** make the engine bind *as* the rotated account itself (self-bind, `binddn == dn`).
  That topology rotates exactly **once**: an LDAP static-role rotation updates only the role
  record, never the engine's stored `bindpass`, so after the first rotation the engine can no
  longer bind and the second rotation fails. `rotate-root` would update the bind password but
  its value is intentionally non-retrievable, so IVIA could never re-bind. The self-bind pattern
  was built and proven a one-shot trap.
- Either way, IVIA bakes the bind password into its config DB **at autoconf config time**, so
  each rotation requires a full autoconf re-run (~12–15 min, recreates
  `iviaruntime`/`iviawrprp1`) for IVIA to re-resolve `!secret`. That reseed cost is inherent to
  IVIA, independent of the Vault topology.

## Inputs

| Variable | Purpose |
|---|---|
| `region` | AWS region (tagging) |
| `cluster_name` | EKS cluster name (tagging) |
| `icr_entitlement_key` | ICR pull credential (builds `dockerlogin` Secret) |

## Outputs

| Output | Purpose |
|---|---|
| `namespace` | `verify-access` |
| `ivia_wrp_alb_hostname` | ALB hostname for browser flows (OIDC entry point) |
| `ivia_admin_password` | Generated LMI admin password (sensitive) |

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
| autoconf Job fails on first apply with "trust store empty" / "DB cannot be contacted" | LMI bring-up not done yet | Operator must complete the 4 manual LMI steps before terraform apply reaches the Job. See `workshop/content/40-platform/42-deploy-verify-access/` for the port-forward + step-by-step procedure. |
| autoconf Job aborts with `KeyError: 'pnr_id'` in `push_notifications()` (only when `push_notification_providers` already exist) | Upstream `ibmvia_autoconf` SDK bug — update path reads the wrong API field and mis-matches providers that share an `app_id`. See [Vendored SDK patch](#vendored-sdk-patch--push_notifications-keyerror-pnr_id) below. | The autoconf Job applies a fail-loud in-place patch before running. No action needed; if the patch's expected source lines are absent the Job exits non-zero rather than running unpatched. |

## Vendored SDK patch — `push_notifications()` `KeyError: 'pnr_id'`

The autoconf Job pins `ibmvia_autoconf==0.3.21`. Its `AccessControl.push_notifications()` has a bug on the **update** path (i.e. only when the providers already exist, so it surfaces on the *second* and later applies, not the first). The Job patches it in place — fail-loud, idempotent — between `pip install` and `cd /base_layer` (see `module.ivia` autoconf Job command in `main.tf`).

Two defects, both still present in the latest published SDK **0.3.41** (verified by inspecting the 0.3.41 sdist; `access_control.py` lines 106 + 108 are unchanged):

1. **Wrong API field.** It reads the existing provider id as `old_pnp['pnr_id']`, but the IVIA `GET /iam/access/v8/push-notification` list response keys the id as `push_id`. The `KeyError: 'pnr_id'` is itself proof the key is absent. (`pnr_id` is the correct *argument* name for `pyivia`'s `update_provider(pnr_id, …)` — the SDK simply pulls it from the wrong response field.)
2. **Match by `app_id` alone.** It selects the existing provider with `filter_list('app_id', provider.app_id, …)`. Apple and Android share one `app_id` (`com.ibm.security.verifyapp`), so both desired providers collapse onto whichever live provider matches first — the second is mis-targeted. The SDK's own docstring example (access_control.py lines 59-68) shows two providers sharing one `app_id`, differing only by `platform`, so the supported config triggers the defect.

The patch matches on `app_id` **and** `platform`, and reads `push_id` (falling back to `pnr_id`). If the expected upstream source lines are not found, the Job exits non-zero rather than running unpatched — it never silently no-ops.

> **Upstream issue:** report this against `https://github.com/lachlan-ibm/ibmvia_autoconf` (author Lachlan Gleeson). Until fixed upstream and the pin is bumped, the in-Job patch is the fix of record. Remove the patch only after bumping the pin to a release that resolves it.

## Phase 7 plan references

- `.planning/phases/07-ivia-deployment-refactor/07-CONTEXT.md` — 21 locked decisions.
- `.planning/phases/07-ivia-deployment-refactor/07-RESEARCH.md` — ~1700-line technical reference.
- `.planning/phases/07-ivia-deployment-refactor/07-10-VERIFICATION.md` — this plan's smoke-test runbook.
- Sibling working artifacts: `~/git-repos/verify-access-container-deployment/`.
