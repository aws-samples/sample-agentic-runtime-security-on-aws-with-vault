# Provisioning-Order Refactor — Plan

## Problem

One whole-root `terraform apply` creates the end-user app pods (uc1 / uc2 / uc3) before their out-of-graph prerequisites exist — container images in ECR and Vault roles — so pods sit in ImagePullBackOff (30+ min) and Vault-403 CrashLoop. The earlier fix (bash `terraform apply -target=` "waves" staging the foundation) is REJECTED: provisioning order belongs in Terraform's dependency graph, not in the bash configuration script.

## Principle — three tiers

1. **Core infrastructure first** (Terraform, all at once): VPC, EKS, add-ons (incl. cert-manager + external-dns + the **Let's Encrypt / ACME ClusterIssuer** — the cert-issuance machinery IVIA depends on), RDS, Bedrock KB, ECR, IAM, ACM, observability. **No pods.**
2. **Shared services next — the intermediate tier:** deploy AND fully configure **Vault and IVIA**. These are *deployable workloads* — not core infrastructure, and not end-user apps. They must be fully ready (Vault roles created, IVIA OIDC live on its trusted FQDN) **before any app starts**.
3. **End-user workloads last:** uc1 / uc2 / uc3, deployed after their images (ECR), Vault roles (tier 2), and IVIA OIDC (tier 2) all exist.

Order across each seam is **structural** (a Terraform `terraform_remote_state` dependency), not a bash convention.

## Forced facts (not choices)

- **Vault server + IVIA are not core infra.** They are pods on the cluster (Vault Helm release; IVIA iviaop / WRP / runtime + autoconf in `verify-access`). They form the intermediate services tier — deployed after the cluster exists, fully configured before the apps deploy. This is *why* a single-root apply "happens to work" for them but mis-models the architecture.
- **End-user apps cannot deploy before tier 2 is fully configured.** A uc pod needs its Vault role at boot (created by `vault-config`, which needs a live, *initialized* Vault) and needs IVIA's OIDC for the OAuth flow. Both are tier-2 outputs.
- **Images build after tier 1, before tier 3.** uc images are env-agnostic (no `--build-arg`; config injected as k8s env at deploy); only prerequisite = the ECR repos (tier 1). May run in parallel with tier 2. (IVIA images come from IBM ICR via its licensing pull secret — NOT built by `build-images.sh`, so tier 2 has no `build-images` dependency.)
- **Vault roles stay Terraform** (`vault-config/` root); run in tier 2 after the Vault server is deployed + `vault operator init` (root token must never land in TF state, so init stays a script).
- **The cert-issuance machinery is foundational (tier 1).** cert-manager + external-dns + the Let's Encrypt / ACME ClusterIssuer are in place *before* IVIA deploys, so IVIA mints its trusted cert against a ready issuer. The IVIA-*specific* cert is still minted at IVIA-deploy time — the nip.io FQDN `wrp.<deploy_id>.<alb_ip_dashed>.nip.io` encodes IVIA's WRP ALB IP, which exists only once IVIA's Ingress is up — so the cert mint + ACM import live in Phase 2, consuming the tier-1 issuer by name. No backward tier-2 → tier-1 edge.

## Target flow

- **Phase 1 — Core infrastructure:** `terraform -chdir=infrastructure apply` → VPC, EKS, add-ons, RDS, Bedrock KB, ECR, IAM, ACM, observability. No Vault, no IVIA, no apps.
- **Phase 2 — Shared services (deploy + configure Vault & IVIA):**
  - `terraform -chdir=infrastructure/services apply` → Vault server (Helm) + IVIA (iviaop / WRP / runtime / autoconf + ICR pull secret) + iviaop client patch.
  - `vault-init` (operator init / unseal) · `vault-configure` (auth, policies, k8s roles).
  - IVIA nip.io / ACME handoff: mint IVIA's FQDN cert via the tier-1 Let's Encrypt issuer → ACM import (bash) → re-apply the services root onto the trusted FQDN · `vault-configure` pass 2 (JWT issuer rebind to IVIA) · `ivia-configure`.
  - **Exit gate:** Vault unsealed + roles present; IVIA OIDC discovery `200` on the trusted FQDN (no `-k`).
- **Phase 3 — End-user workloads:** `terraform -chdir=infrastructure/workloads apply` (full graph, no `-target`) → uc1 / uc2 / uc3. Images + Vault roles + IVIA OIDC all present → clean boot.
- **Phase 4 — Seed + verify:** seed banking DB · run `verify-uc1/2/3`.

`build-images.sh` runs after Phase 1 (ECR exists), before Phase 3 — may overlap Phase 2.

## Mechanism — three roots (Option A, extended)

Three Terraform roots, each reading the prior tier via `terraform_remote_state` (backend `local`, `../terraform.tfstate`) — the same pattern the existing `vault-config/` root already uses:

- `infrastructure/` — **tier 1**, core infra.
- `infrastructure/services/` — **tier 2**, Vault server + IVIA (deploy). Reads tier 1.
- `infrastructure/workloads/` — **tier 3**, uc1 / uc2 / uc3. Reads tier 1 + tier 2.
- `infrastructure/vault-config/` — Vault roles/policies (the *configure* half of tier 2); runs after the tier-2 Vault deploy + init. Unchanged pattern.

Ordering is **structural**: tier 3 cannot apply before tier 2 (its `remote_state` read would fail); tier 2 cannot apply before tier 1. "Order in the graph, not in bash." Each root applies full-graph, no `-target`.

## Code changes

**Tier-1 root `infrastructure/`**
- REMOVE: Vault server (Helm release); `module.ivia` + `kubernetes_config_map_v1_data.iviaop_clients_patch` + `null_resource.iviaop_rollout_restart`; modules `uc1_agent` / `uc2_app` / `uc3_agent`.
- KEEP: core infra + the cert-issuance machinery (cert-manager, external-dns, the Let's Encrypt / ACME ClusterIssuer). Expose via `outputs.tf` (most already): cluster endpoint / CA / name, region, vpc / subnets, `rds_endpoint`, ACM `tls_certificate_arn`, KB id, audit / glue.

**New tier-2 root `infrastructure/services/`**
- Backend `local`, `infrastructure/services/terraform.tfstate`.
- providers (aws + kubernetes + helm 2.17 + kubectl) from tier-1 `remote_state` outputs.
- `remote_state.tf` → `../terraform.tfstate` (tier 1).
- Vault Helm release + `module.ivia` + iviaop client patch + rollout restart + IVIA host-resolution locals (read `../.acme-state`) + the IVIA ICR licensing pull secret.
- Outputs: `ivia_issuer`, `ivia_oidc_ca_pem`, Vault address/release info — consumed by tier 3 + `vault-config`.

**New tier-3 root `infrastructure/workloads/`**
- Backend `local`, `infrastructure/workloads/terraform.tfstate`.
- providers from tier-1 `remote_state`.
- `remote_state.tf` → tier 1 (`../terraform.tfstate`) + tier 2 (`../services/terraform.tfstate`).
- `variables.tf`: image vars (`uc1_agent_image`, `banking_app_*`, `uc3_agent_image`).
- `main.tf`: modules uc1 / uc2 / uc3. Cross-tier refs (vault / rds / ivia) collapse to "tier exists" via `remote_state` — most load-bearing `depends_on` become unnecessary.

**`vault-config/` root** — unchanged pattern; sequenced inside Phase 2 (after Vault deploy + init). Reads tier-1 (cluster) `remote_state`; binds the JWT issuer to IVIA in pass 2.

**`deploy-workshop.sh`** — orchestrate the 4 phases in order; every `terraform apply` / sub-script a hard `|| die` barrier; every ALB / cert / DNS wait timeout-bounded. Init all roots.

## Blast radius — other scripts & content

- **`workshop-e2e.sh`** — Vault/IVIA steps retarget tier-2 `infrastructure/services`; per-UC applies retarget tier-3 `infrastructure/workloads`; observability stays tier-1; `--nuke` destroys tier 3 → tier 2 → tier 1 (reverse of deploy). Fix `init -upgrade` → bare `init` (violates the no-init-upgrade rule).
- **`teardown.sh`** — destroy ORDER: workloads → services → infrastructure; the keep-eks state-list logic must read all three roots.
- **`bootstrap.sh`** — `terraform init` all three roots (currently only tier 1).
- **Sequencing-only (no code change):** `build-images.sh` (ECR stays tier 1), `seed-banking-db.sh`, `sync-bedrock-kb.sh`, `verify-uc1/2/3.sh`, `test-*.sh`.
- **Workshop content:** `30-deploy-foundation/31-deploy-stacks/index.en.md` rewrite (Step 2 = core infra only; services + workloads deployed by `deploy-workshop.sh`, not attendee-visible per the decision below); `30-deploy-foundation/index.en.md:6`, `50-use-case-1/index.en.md:12`, `60-use-case-2/index.en.md:51` corrected. `docs/IVIA_Deployment.md` — iviaop patch moves to the services root.

## Idempotency & testing

- All three roots re-appliable (second run = no-op); the workloads apply skips when converged; the ACME handoff guarded by `.acme-state`.
- **BLOCKING gate before any PR:** re-run the full `deploy-workshop.sh` path END-TO-END against the live cluster — tier-1 apply, tier-2 deploy + configure (Vault roles present, IVIA OIDC `200` on the FQDN no `-k`), tier-3 apply (all uc deployments `Available`, no ImagePullBackOff / Vault-403), seed OK. Second run → clean (idempotent).
- Pre-live dry-run: `bash -n` + `shellcheck -x` + `--dry-run` exit 0 (zero AWS / cluster mutation). Bear runs the live pass.

## Close-out

Branch `feat/provisioning-order-refactor`. Atomic commits, explicit `git add <path>`. LOCAL only until the live gate passes; then PR (two-section `## Features` / `## Fixes`) → `gh pr merge --merge --delete-branch` → clean `main`.

## Decisions (locked) & open questions

**Locked:**
1. **Three tiers:** core infra → shared services (Vault + IVIA, deploy + fully configure) → end-user workloads. Vault server + IVIA are NOT core infra; they are the intermediate services tier.
2. Mechanism = **three Terraform roots** (`infrastructure/` · `infrastructure/services/` · `infrastructure/workloads/`) plus the existing `vault-config/`, wired via `terraform_remote_state`. Ordering structural.
3. All deploy/config runs **inside `deploy-workshop.sh`** — not an attendee-visible step.
4. Local state per root (`<root>/terraform.tfstate`).
5. A cold full foundation apply needs **no `-target`** — confirmed empirically (Bear's clean apply 2026-06-08; `providers.tf` refactored to `module.eks` outputs on 2026-05-20, `bf59230`, the `data.aws_eks_cluster` source is gone). `IVIA_Deployment.md`'s "Kubernetes cluster unreachable" providers claim is stale.
6. **Cert-issuance machinery is foundational (tier 1).** The Let's Encrypt / ACME ClusterIssuer + cert-manager + external-dns deploy in tier 1, in place before IVIA. IVIA's *specific* FQDN cert is minted at IVIA-deploy (Phase 2) against that issuer and imported to ACM via bash — the nip.io name encodes IVIA's ALB IP, so the mint can't precede IVIA's Ingress. No backward tier-2 → tier-1 edge. (Resolves the earlier open ACME question.)

**Open:** _(none outstanding)_
