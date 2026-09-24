# Agentic Runtime Security on AWS

Step-by-step **hands-on** AWS Workshop Studio workshop that deploys the IBM Verify + HashiCorp Vault reference architecture for runtime AI agent security on EKS. Attendees follow guided modules to provision and verify three progressively-layered use cases on a single `us-west-2` cluster: workload identity (UC1), OAuth user identity (UC2), CIBA mobile-push approval for privileged writes (UC3).

**Duration:** ~2 hours minimum end-to-end (longer if attendees pause to inspect Vault policies, IVIA decisions, or the Athena audit correlation between modules).

**Audience:** workshop admins running this for their orgs. Attendee-facing pages live in `workshop/content/`.

**Latest release:** [v0.15.0](https://github.ibm.com/Oscar-Medina/agentic-runtime-security-aws/releases/latest) — UC1/UC2/UC3 all green end-to-end.

![Reference architecture](assets/architecture-overview.svg)

---

## Delivery

Hosted on AWS Workshop Studio v2. Attendees consume the workshop as 39 guided `index.en.md` pages (`workshop/content/**`). Admin deploys the whole stack with one `bash infrastructure/scripts/deploy-workshop.sh` invocation against an AWS account they own. See "Quick start (admin)" below and "Workshop content (preview + publish)" further down.

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

## Browser-trusted TLS (shared magic-DNS domain)

Every attendee's browser-trusted certificate comes from Let's Encrypt over a `nip.io` hostname, which resolves an IP embedded in the name (`10-1-2-3.nip.io` → `10.1.2.3`). That is what gets a publicly-trusted certificate with no domain purchase and no DNS hosting.

`nip.io` is **not** on the Public Suffix List, so every `*.nip.io` certificate on the internet — not just this workshop's — counts against the single registered domain `nip.io`. Let's Encrypt budgets certificates per registered domain, so the whole internet draws on one bucket.

**This is not a capacity limit, and event size is irrelevant.** `nip.io` holds a Let's Encrypt override of 250,000 certificates, far above any cohort; each attendee burns one. The real risk is that the bucket is shared and has been exhausted before — the operator's sibling domain `sslip.io` hit `too many certificates (50000) already issued` in February 2026. There is no way to check the remaining budget or reserve it ahead of an event.

**The deploy handles this automatically.** If Let's Encrypt refuses `nip.io` as rate limited, `deploy-workshop.sh` re-issues on `sslip.io` — a separate registered domain with its own separate budget, and the fallback the `nip.io` operator itself recommends. Both suffixes are overridable if you run your own magic-DNS host:

```bash
TLS_DNS_SUFFIX=my.example.com TLS_DNS_SUFFIX_FALLBACK=alt.example.com bash infrastructure/scripts/deploy-workshop.sh
```

Changing the suffix on an **already-deployed** environment must reach tier 3. The certificate is issued in tier 2, but the banking-UI Ingress host is built by tier 3 from `.acme-state`. Stop at `--tier 2` and the two disagree: the ALB still routes the old hostname, which the new certificate no longer covers, so banking answers `404` on the new name and fails TLS name validation on the old one. Run the deploy without `--tier` (all tiers), or follow a `--tier 2` run with `--tier 3`. The deploy warns when it detects this.

If both budgets are exhausted the deploy fails loudly at Step 7 and names the override — it does not silently retry the same exhausted domain. Tracked in [issue #5](https://github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault/issues/5).

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

## One-page flyer

A printable one-pager for promoting the workshop — what it is, who it is for, the three agents you build, the two ways to run it, and a QR code to the published Workshop Studio catalog entry.

```bash
# Regenerate assets/flyer/workshop-flyer.html — open or print it from a browser.
bash assets/flyer/build-flyer.sh

# ...and a print-ready PDF alongside it, for sending to a printer or attaching.
bash assets/flyer/build-flyer.sh --pdf

# ...and an Outlook-safe rich-HTML version, for pasting into an email.
bash assets/flyer/build-flyer.sh --email
```

Requires `qrencode` (`brew install qrencode`); `--pdf` also needs Google Chrome or Chromium, which the script finds on its own. Everything else runs on a stock `python3` with no `pip install` and no `npm install`.

Edit `assets/flyer/flyer.template.html` for any copy, colour or layout change, then re-run. Nothing in the output is hand-edited — the logos, the QR code and the URL are all generated:

- **Logos.** Neither shipped mark works on the flyer's dark ground. `assets/aws-logo.png` is a dark navy wordmark, and `assets/hashicorp_logo.png` is a black hexagon on a *solid white field with no transparency at all* — it renders as a white box. The build recolours the AWS wordmark to white while leaving the orange smile alone, and keys the HashiCorp field out by luminance so the mark comes through white with its anti-aliased edges intact. Both are the official reversed variants.
- **QR code.** Rebuilt from `qrencode`'s module grid into a single SVG path (its native output is ~52 KB of individual `<rect>` elements) and inlined, so the flyer makes no external image requests and prints crisp. Point it somewhere else with `WORKSHOP_URL=<url> bash assets/flyer/build-flyer.sh`.

- **PDF.** `--pdf` prints `workshop-flyer.pdf` through headless Chrome — one Letter page, dark ground intact, Inter and JetBrains Mono embedded, and the text still selectable. The template carries a print stylesheet that does two things the screen layout does not need: it compacts spacing so the content fits a single page, and it prints the headline in flat ink, because Chrome's print pipeline ignores `background-clip: text` and paints the gradient as a solid box over the glyphs. The page carries a 16mm margin all round and the sheet keeps a small gutter inside it, because the AWS mark has ink in its first pixel column and gets shaved flush against the trim. No body copy goes below 12px (9pt at print scale). Printing from the browser's own dialog gives the same result, but only with **Background graphics** ticked.
- **The build fails loud.** `--pdf` asserts the result is exactly one page and, where `zbarimg` and `pdftoppm` are installed, that the QR still decodes to `WORKSHOP_URL` at 100 dpi — well under what a phone camera gets off a printed sheet. A longer `WORKSHOP_URL` wraps the footer link and can push the layout over; the guard catches that instead of handing back a silent two-pager.
- **Email.** `--email` writes `email-flyer.html` from its own source, `assets/flyer/email.template.html` — a separate file, because the print flyer cannot be reused. Outlook on Windows lays out mail with the **Word** engine, which ignores CSS grid, flex, float, gradients and `background-clip`, and drops `background-color` on block elements while still honouring the `bgcolor` *attribute*. So the email version is nested tables with inline styles only, every coloured cell carrying both `bgcolor` and `background`, the headline gradient approximated by colouring each word, and the logos and QR embedded as base64 **PNG** (Word renders no SVG at all). Rounded corners are kept: the Word engine drops `border-radius` and renders the square box it would render anyway, while new Outlook, OWA, Apple Mail and Gmail round properly. To use it: open `assets/flyer/email-flyer.html` in a browser, Select All, Copy, paste into the message — the clipboard carries the table backgrounds and the embedded images with it. The build asserts what silently breaks: at least ten `bgcolor` attributes, no banned property in the body, no rounded cell on a `border-collapse:collapse` table (the radius would be dropped), exactly three embedded images, and — where `zbarimg` is installed — that the QR decodes to `WORKSHOP_URL`.
- **Fonts.** Inter and JetBrains Mono ship in `assets/flyer/fonts/` and are inlined as `@font-face` data URIs, so the flyer renders identically with no network at all — which is also what makes the PDF embed the real faces instead of substituting a system sans. Both are SIL Open Font License 1.1; the upstream license texts travel with them as `Inter-LICENSE.txt` and `JetBrainsMono-LICENSE.txt` in that same directory.

The built `workshop-flyer.html` and `email-flyer.html` are committed alongside their sources: it is self-contained and it is the file you actually open. `workshop-flyer.pdf` is **not** committed (`*.pdf` is gitignored repo-wide) — run `--pdf` when you need it.

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
| `verify-uc3.sh --no-phone` | Admin with no IBM Verify app | Drives the whole UC3 refund live — enrols a throwaway virtual authenticator over the same OAuth + SCIM endpoints the IBM Verify app uses, signs the real user-presence challenge, asserts the refund row in RDS, then prints the three-plane Athena correlation for the refund it just produced. Nothing is stubbed: IVIA resolves the transaction on its own evidence and approval stays bound to the exact transaction the agent fired. Refuses to run if a real phone is enrolled, and never leaves a device behind. |
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

File issues at <https://github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault/issues>. Testing playbook: [`TESTING-PLAYBOOK.md`](TESTING-PLAYBOOK.md).

## License

MIT-0 (AWS Workshop Studio convention).
