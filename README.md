# Agentic Runtime Security on AWS

Step-by-step **hands-on** AWS Workshop Studio workshop that deploys the IBM Verify + HashiCorp Vault reference architecture for runtime AI agent security on EKS. Attendees follow guided modules to provision and verify three progressively-layered use cases on a single `us-west-2` cluster: workload identity (UC1), OAuth user identity (UC2), CIBA mobile-push approval for privileged writes (UC3).

**Duration:** ~2 hours minimum end-to-end (longer if attendees pause to inspect Vault policies, IVIA decisions, or the Athena audit correlation between modules).

**Audience:** workshop admins running this for their orgs. Attendee-facing pages live in `workshop/content/`.

**Latest release:** [v0.15.0](https://github.ibm.com/Oscar-Medina/agentic-runtime-security-aws/releases/latest) — UC1/UC2/UC3 all green end-to-end.

![Reference architecture](assets/architecture-overview.svg)

---

## Distributions

The workshop ships in **two** parallel distributions. Both deploy the same underlying AWS reference architecture and share every script under `infrastructure/scripts/`, every Terraform module under `infrastructure/modules/`, and every page of narrative under `workshop/content/`. Choose the distribution that matches your delivery channel.

### AWS Workshop Studio (`workshop/`)

Hosted on AWS Workshop Studio v2. Attendees consume the workshop as 39 guided `index.en.md` pages (`workshop/content/**`). Admin deploys the whole stack with one `bash infrastructure/scripts/deploy-workshop.sh` invocation against an AWS account they own. See "Quick start (admin)" below and "Workshop content (preview + publish)" further down.

### Instruqt (`instruqt/`)

Hosted on Instruqt as a single ~4-hour mega-track. Each attendee receives a fresh **Instruqt-provisioned AWS sandbox account** and works through 18 challenges that drive the same `deploy-workshop.sh` orchestration in three tiers (one challenge per tier), then walk the three use cases end-to-end. The 14-step deploy is split via the `--tier <1|2|3>` flag on `deploy-workshop.sh`; AWS credentials, SSH deploy key, and IBM licensing artifacts are injected from Instruqt org secrets so the attendee never touches plaintext. See `instruqt/README.md` for the full authoring + publish loop.

---

## Quick start (admin)

```bash
# 1. Preview the workshop content locally before deploying anything
bash workshop/scripts/preview.sh

# 2. Verify your CLI tools + AWS account + Bedrock access
bash infrastructure/scripts/check-prerequisites.sh

# 3. Deploy the full stack and run all use-case verifications
bash infrastructure/scripts/workshop-e2e.sh --interactive --skip-teardown

# 4. Spot-check each use case (run individually as needed)
bash infrastructure/scripts/verify-uc1.sh
bash infrastructure/scripts/verify-uc2.sh
bash infrastructure/scripts/verify-uc3.sh
bash infrastructure/scripts/verify-uc3.sh --bypass    # negative tests (forged JWT, missing may_act)

# 5. Tear down everything (no orphans)
bash infrastructure/scripts/teardown.sh
```

All scripts are idempotent. `workshop-e2e.sh --help` lists every flag (`--start-from`, `--dry-run`, `--teardown-only`, `--nuke`, etc.).

---

## Required licenses (must obtain before deploy)

IVIA deploy requires **two artifacts from IBM**. You supply one; the other ships with the workshop:

1. **IBM Container Registry entitlement key** — lets the cluster pull `icr.io/ibm-vassd/verify-access:11.0.2` images. From IBM Cloud → Container Software Library.
2. **IVIA 90-day trial activation certificate** — unlocks the IVIA server at runtime. Ships bundled with the workshop at `infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer`; Terraform reads it automatically, so there is nothing to obtain or upload.

You supply the entitlement key in `infrastructure/terraform.tfvars`. Full details: [`workshop/content/20-prerequisites/22-ivia-licensing/`](workshop/content/20-prerequisites/22-ivia-licensing/index.en.md).

Bedrock access required: enable `us.amazon.nova-pro-v1:0` (Nova Pro via CRIS) in `us-west-2` and `amazon.nova-2-multimodal-embeddings-v1:0` in `us-east-1` for the Knowledge Base.

---

## Event capacity (multi-attendee TLS limit)

Browser-trusted TLS is issued per attendee account from Let's Encrypt over `nip.io` hostnames. `nip.io` is **not** on the Public Suffix List, so every `*.nip.io` certificate on the internet — not just this workshop's — counts against the single registered domain `nip.io`, which Let's Encrypt caps at **50 certificate issuances per rolling 7 days** (~1 refill every 202 min). Each attendee's Tier-2 deploy burns **one** issuance (more if the Step 7 HTTP-01 readiness gate retries); teardown does **not** refund it.

Plan events accordingly:

- **~12–20 attendees per event.** 12 is the safe floor — the 50/week bucket is shared with every `nip.io` user on the internet, and your own retries burn extra; 20 is the upper edge for a low-usage week. Never plan against the full 50 — you never own the whole bucket.
- **One event per rolling 7-day window — no back-to-back weeks.** A prior event's issuances stay counted for 7 days; space events **≥7 days apart** so they age out of the window and the refill replenishes.
- Even 12–20 can fail in a heavy-usage week — the bucket is shared and there is **no way to check remaining budget or reserve it in advance**.

To run larger cohorts (20–60) reliably, move off the shared `nip.io` bucket onto an owned domain + self-hosted magic-DNS resolver + a Let's Encrypt rate-limit override — tracked in [issue #54](https://github.com/sharepointoscar/agentic-runtime-security-aws/issues/54).

---

## Optional: pre-built images from GHCR (bring your own)

The workshop deploys five container images. **The default and supported path is ECR** — `deploy-workshop.sh` builds the images from source and pushes them to your own account's private ECR (needs Docker or Podman). The workshop walkthrough only covers this ECR path.

As an **optional, advanced opt-out**, you can skip the local build and have the pods pull pre-built public images from GHCR instead (`--image-source ghcr`). This is **bring-your-own**: there is **no default namespace** — you publish the five images to your *own* GHCR namespace first, then point the deploy at it. If you select `ghcr` mode without a base, the deploy fails fast before any AWS work. This path is documented here only, not in the attendee walkthrough.

**1. Prerequisites** — a GitHub account with the `write:packages` scope on your CLI token, and a running container runtime (publishing builds the images locally before pushing):

```bash
gh auth refresh -h github.com -s write:packages
```

**2. Publish the five images to your namespace** — the script reads the `write:packages` token from `GHCR_PAT` or `gh auth token`:

```bash
export GHCR_PAT=$(gh auth token)
bash infrastructure/scripts/publish-images.sh --registry-base ghcr.io/<githubusername>
```

**3. Make the five packages Public** — via the GitHub web UI (Settings → Packages on your profile); there is no REST API for container-package visibility. The package names (under `ghcr.io/<githubusername>/`) are `workshop-uc1-agent`, `workshop-banking-app-ui`, `workshop-banking-app-agent`, `workshop-banking-app-mcp`, `workshop-uc3-agent`.

**4. Deploy pointing consume at your base** — pass `--image-source ghcr` and `--ghcr-registry-base` on every tier:

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1 --image-source ghcr --ghcr-registry-base ghcr.io/<githubusername>
bash infrastructure/scripts/deploy-workshop.sh --tier 2 --image-source ghcr --ghcr-registry-base ghcr.io/<githubusername>
bash infrastructure/scripts/deploy-workshop.sh --tier 3 --image-source ghcr --ghcr-registry-base ghcr.io/<githubusername>
```

**Gotcha — publish base must equal consume base.** The `--registry-base` you pass to `publish-images.sh` and the `--ghcr-registry-base` you pass to `deploy-workshop.sh` must be identical. Pointing consume at a base where the packages do not exist, or are still Private, yields `ImagePullBackOff` on all five pods with no other error.

**Updating one image after a change** — republish only that image at the next version, bump the matching `ghcr_*` pin in `infrastructure/workloads/main.tf`, then re-deploy Tier 3 (a new tag makes Terraform roll the Deployment):

```bash
bash infrastructure/scripts/publish-images.sh --image banking-ui --version v2 --registry-base ghcr.io/<githubusername>
```

---

## Workshop content (preview + publish)

Attendee-facing pages live under `workshop/content/` (Hugo + AWS Workshop Studio v2 contentspec). Three admin actions:

```bash
# Preview locally — auto-downloads the AWS Workshop Studio preview CLI on first run,
# caches it at workshop/tmp/preview_build, then serves http://localhost:8080.
# Open that URL in a browser to read the workshop exactly as attendees will.
bash workshop/scripts/preview.sh

# Sync diagram SVGs from assets/ into workshop/static/images/ (run before publish).
bash workshop/scripts/package-assets.sh

# Publish to AWS Workshop Studio with an explicit version tag.
bash workshop/scripts/publish.sh <version>    # e.g. 0.15.0
```

Edit content under `workshop/content/<NN-section>/index.en.md` (or `<NN-section>/<NN-subpage>/index.en.md`). The preview reloads on file change — keep it running in a side terminal while editing.

---

## Slide deck (presenter mode)

The slide deck `slides.md` is reveal-md markdown; it lives in the sibling worktree `../agentic-runtime-security-aws-slides/`. From that directory:

```bash
# Live present (opens browser at http://localhost:1948, hot-reloads on edit)
npx reveal-md slides.md

# Export to PDF for offline / printed handouts.
# --print-size 1280x720 is REQUIRED: it matches the PDF page to the 16:9 slide
# size. Without it reveal-md prints a ~4:3 page and clips the right edge.
npx reveal-md slides.md --print slides.pdf --print-size 1280x720
```

No build step — `reveal-md.json` next to `slides.md` carries the theme + transition config.

---

## Admin-only test + diagnostic scripts

The workshop content never shows attendees these. Use them to isolate problems, sanity-check a fresh deploy, or re-run a single layer after a change. All live under `infrastructure/scripts/`.

| Script | When to run | What it checks |
|---|---|---|
| `workshop-e2e.sh` | Full clean deploy + validate | Phases 0–8: prerequisites → bootstrap → `terraform apply` → kubectl config → foundation tests → IVIA → Vault init/config → UC1/UC2/UC3 → optional teardown. `--start-from <phase>` resumes; `--dry-run` previews. |
| `e2e-validate.sh` | After any layer change | Runs every `verify-*.sh` + `test-*.sh` end-to-end and emits one summary. Use this to confirm nothing regressed before opening a PR. |
| `test-foundation.sh` | After `terraform apply` | EKS + RDS + Bedrock KB + OpenLDAP all healthy. |
| `test-eks.sh` | If pods won't schedule | Cluster nodes Ready, addons running, IAM/IRSA wired. |
| `test-rds.sh` | If DB connections fail | Instance status, parameter group, pgaudit + RLS enabled. |
| `test-bedrock-kb.sh` | If UC1 `/query` is empty | KB exists, AOSS collection ready, S3 corpus has objects, ingestion job succeeded. Pair with `sync-bedrock-kb.sh` to re-ingest. |
| `test-vault-verify.sh` | After Vault unseal / re-init | Vault auth methods + secrets engines + policies present. |
| `verify-uc1.sh` / `verify-uc2.sh` / `verify-uc3.sh` | Per use case | See the table below. |
| `verify-uc3.sh --bypass` | Adversarial check | Forged HS256 JWT and a real IVIA token with the wrong `act.sub` / a mismatched `vault:path_access` RAR are both rejected by Vault — proves the agent-registry alias + per-request RAR actually gate access. |
| `show-audit-correlation.sh` | After a UC3 refund | Runs the three-plane Athena correlation query for a given `request_id` and prints the single forensic row. |
| `sync-bedrock-kb.sh` | After corpus changes | Re-ingests the KB so retrieval matches the current corpus. |

Every `verify-*.sh` and `test-*.sh` script is non-destructive, prints `✓ PASS / ✗ FAIL / ⚠ WARN` markers, and exits non-zero on any FAIL so you can chain them in CI.

---

## What gets deployed

Single-region (`us-west-2`) EKS 1.34 cluster running:

- **HashiCorp Vault Enterprise `2.0.3-ent`** (Raft 3-node, KMS auto-unseal, autoloaded `platform-standard` license) — non-human IAM, JIT credentials, and the **native Agent Registry + OAuth resource server** primitives adopted in Phase 9. Every agent is a first-class registered identity; UC2/UC3 authorize Vault directly with the IVIA OAuth JWT (`X-Vault-Token`, no `jwt_login`), enforced by human-baseline ∩ agent-ceiling ∩ per-request `vault:path_access` RAR.
- **IBM Verify Identity Access 11.0.2** — 7 pods: `iviaconfig` (LMI), `iviaruntime` (AAC), `iviadsc` (DSC), `iviawrprp1` (WebSEAL reverse proxy), `iviaop` (OIDC Provider), `openldap`, `postgresql`. Owns human IAM, OAuth, CIBA.
- **UC1/UC2/UC3 Strands agents** plus the banking-app UI for UC2/UC3.
- **RDS PostgreSQL** with Row-Level Security + pgaudit.
- **Bedrock Knowledge Base** (AOSS + Nova 2 Multimodal Embeddings, us-east-1) and Nova Pro inference (us-west-2 via CRIS).
- **Three-plane audit pipeline** — fluent-bit → Firehose → S3 → Glue → Athena workgroup `workshop`.

State lives locally in `infrastructure/terraform.tfstate`. No HCP, no Terraform Stacks.

---

## Use cases (admin TL;DR)

| | What it proves | TTL | Verify |
|---|---|---|---|
| **UC1** — Non-personalized read-only | Vault Kubernetes auth → JIT Postgres + Bedrock STS. No standing creds. | 15m | `verify-uc1.sh` (9 checks) |
| **UC2** — OAuth personalized read-only | Authorization Code + PKCE via IVIA → per-user JIT creds → Postgres RLS. ENFC-02 (no INSERT) + ENFC-03 (NetworkPolicy egress block). | 15m | `verify-uc2.sh` (14 checks) |
| **UC3** — CIBA privileged write | Mobile-push approval via **IBM Verify app** on the admin's phone → RFC 8693 token exchange (`act.sub=uc3-actor`) + RFC 9396 RAR (`type: vault:path_access`) enforced natively by Vault's OAuth resource server (agent-ceiling ∩ per-request RAR) → three-plane Athena audit correlation by `request_id`. | 5m | `verify-uc3.sh` (15 checks) + `--bypass` (2 negative tests) |

UC3 requires the free **IBM Verify** app installed on a phone (App Store / Google Play) **before** running the refund flow — used for the mobile-push approval. Enrollment URL is printed by `terraform -chdir=infrastructure output -raw wrp_public_fqdn` plus the path documented at `workshop/content/70-use-case-3/70-enroll-device/`.

---

## Repo map

- `infrastructure/` — Terraform IaC + admin scripts (`workshop-e2e.sh`, `teardown.sh`, `check-prerequisites.sh`, `verify-uc*.sh`, build/seed/config scripts).
- `infrastructure/modules/` — one module per layer; **each module has its own `README.md`** (e.g. `verify_access/README.md` documents the IVIA stack + TLS cert ownership; `vault_config/README.md` documents the Agent Registry, OAuth resource server, and three-layer policy model; `vault_server/README.md` documents the Enterprise edition + license wiring).
- `infrastructure/vault-config/` — separate Terraform root run over a `kubectl port-forward` (Vault provider needs cluster-internal access).
- `workshop/content/` — attendee-facing markdown (Hugo + Workshop Studio v2). Preview via `workshop/scripts/preview.sh`.
- `applications/` — `banking-app/` (UI + agent + MCP server for UC2/UC3) and `uc3-agent/` source.
- `assets/` — SVG architecture diagrams + workshop branding.
- `docs/` — admin-facing runbooks (e.g. `docs/IVIA_Deployment.md` for IVIA destroy/rebuild procedure).
- `slides.md` lives in a sibling worktree: `../agentic-runtime-security-aws-slides/` (not in this repo).

---

## Issues + feedback

File issues at <https://github.ibm.com/Oscar-Medina/agentic-runtime-security-aws/issues>. Workshop-tester role guide: [`TESTING.md`](TESTING.md).

## License

MIT-0 (AWS Workshop Studio convention).
