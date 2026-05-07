# Workshop Testing Guide

This document describes how to test the workshop end-to-end. The workshop is built phase-by-phase; each phase appends its own verification section here. Phase 1 populates the scaffold + pre-flight sections; later phases fill in their own.

## End-to-End Validation

Before running the full workshop or after making changes, validate that the repo skeleton, slide deck preview, SVG regeneration pipeline, and consolidated `preflight.sh` script all work against your AWS account.

### E2E Workshop Flow Checklist

Complete walkthrough to validate the full workshop. Steps marked [MANUAL] require HCP Terraform UI interaction.
Steps marked [WAIT] require waiting for HCP Terraform to apply.

#### Phase 1: Scaffold and Pre-Flight

- [ ] `git clone` produces the same top-level layout as `~/git-repos/eks-terraform-stacks` (README.md, LICENSE, TESTING.md, slides.md, reveal-md.json, assets/, infrastructure/, workshop/)
- [ ] `npx reveal-md slides.md` opens the slide deck in a browser
- [ ] `npx reveal-md slides.md --print slides.pdf` exports the deck to PDF
- [ ] `python3 infrastructure/scripts/excalidraw-to-svg.py` regenerates all six SVGs in `assets/` from their `.excalidraw` sources
- [ ] `./infrastructure/scripts/preflight.sh` installs CLI tools (kubectl 1.33.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws v2, jq, yq) and verifies Bedrock model access (PREF-01) + AWS service quotas (PREF-02) + IAM permissions (PREF-03) + companion to PREF-05
- [ ] `./infrastructure/scripts/bootstrap.sh <HCP_ORG>` creates HCP project + variable set + OIDC trust + IAM role for Stacks (PREF-04)

#### Phase 2: Foundation Infrastructure

*Populated in Phase 2.*

#### Phase 3: Platform and Configuration

*Populated in Phase 3.*

#### Phase 4: Use Case 1 — Non-Personalized Read-Only

*Populated in Phase 4.*

#### Phase 5: Use Case 2 — OAuth Personalized Read-Only

*Populated in Phase 5.*

#### Phase 6: Use Case 3 — CIBA Privileged + Audit Correlation

*Populated in Phase 6.*

#### Phase 7: Cleanup

*Populated in Phase 7.*

---

## Phase 1: Scaffold Verification

The Phase 1 deliverables are the workshop's outer shell — repo skeleton, slide deck, six diagrams, consolidated `preflight.sh` + `bootstrap.sh` scripts, Workshop Studio config, and the `10-introduction/` / `20-prerequisites/` / `99-credits/` content modules. No AWS infrastructure deploys in this phase.

### Repo skeleton verification

```bash
# Top-level files present
test -f README.md
test -f LICENSE
test -f TESTING.md
test -f .gitignore
test -f slides.md
test -f reveal-md.json

# Module directories — bedrock_kb is split into bedrock_kb_aoss + bedrock_kb_index
# (avoids a Stacks circular dependency between the opensearch provider URL and
# the component that creates the AOSS collection). README.md presence is
# optional per CLAUDE.md "minimize .md files" — these dirs may have inline docs only.
for d in audit vpc eks addons rds bedrock_kb_aoss bedrock_kb_index \
         vault verify_access vault_config isva_config \
         observability uc1_agent uc2_agent uc3_agent; do
  test -d "infrastructure/modules/$d" || echo "MISSING: $d"
done

# Scripts directory indexed
test -f infrastructure/scripts/README.md
```

### Slide deck preview verification

```bash
# Preview (opens default browser at http://localhost:1948)
npx reveal-md slides.md

# Export to PDF
npx reveal-md slides.md --print slides.pdf
```

The deck must cover the 5 control objectives (one summary slide + one deep-dive slide per objective = 6 slides), the joint Verify+Vault responsibility split (SKO Slide 13 redrawn for the workshop), and a preview of UC1 / UC2 / UC3.

### SVG regeneration verification

```bash
python3 infrastructure/scripts/excalidraw-to-svg.py
```

Must regenerate all six SVGs in `assets/` from their `.excalidraw` sources without errors:
1. Overall reference architecture
2. UC1 flow
3. UC2 OAuth flow
4. UC3 CIBA flow
5. Audit correlation (combined sequence + log-stores layout)
6. Verify+Vault responsibility split (workshop-native redraw of SKO Slide 13)

### Pre-flight script verification

`preflight.sh` emits colored `✓ PASS` / `✗ FAIL` / `⚠ WARN` markers, indented detail, and a consolidated summary block at the end. Failures include full inline copy-paste remediation (AWS Console path or `aws` CLI command). It continues running through all checks rather than fail-fast (default mode is CI-safe, no interactive prompts; pass `--interactive` for per-section confirmation).

```bash
./infrastructure/scripts/preflight.sh              # PREF-01 + PREF-02 + PREF-03 + PREF-05
./infrastructure/scripts/bootstrap.sh <HCP_ORG>    # PREF-04
```

## Workshop Studio quota auto-provisioning (publisher action)

The five service quotas required by this workshop are NOT declared in `workshop/contentspec.yaml`
(the v2 schema does not surface a `serviceQuotas` field). Instead, the workshop publisher
must configure them in the Workshop Studio admin UI at publish time:

1. Catalog Builder → this workshop → Account Configuration → Service Quotas tab
2. Add each of these (region: us-west-2):
   - EC2 standard vCPUs — quota code `L-1216C47A` — desired value 32
   - VPC Elastic IPs — quota code `L-0263D0A3` — desired value 6
   - RDS DB instances per region — quota code `L-7B6409FD` — desired value 1
   - OpenSearch Serverless OCUs (indexing) — quota code `L-50FA809B` — desired value 2 (AWS quota name: "Default indexing MAX OCU setting", default 10)
   - OpenSearch Serverless OCUs (search) — quota code `L-4E98D4EB` — desired value 2 (AWS quota name: "Default search MAX OCU setting", default 10)

Workshop Studio submits these increases on the attendee account before hand-off, so attendees do
not hit ceilings during Phase 2 deploy. The CONTEXT-locked decision (`01-CONTEXT.md` line 94)
enumerates the four service families; the AOSS family splits into two distinct OCU codes.
Attendees can also self-verify via `infrastructure/scripts/preflight.sh` (its quotas section) and
request increases manually if Workshop Studio's auto-provisioning has not yet completed.

---

## Cross-Platform Compatibility

All workshop scripts are designed to work on both macOS and Linux. Windows / WSL2 is out of scope for v1.

**Shebangs:** All shell scripts use `#!/usr/bin/env bash` for portability across systems where bash may not be at `/bin/bash` (e.g., NixOS, custom installs, Docker containers).

**macOS Bash 3.2:** macOS ships Bash 3.2 due to GPLv3 licensing. Workshop scripts avoid Bash 4+ features (associative arrays, `readarray`) so they work on stock macOS. If a script must use Bash 4+, run it with Homebrew bash:

```bash
brew install bash
/opt/homebrew/bin/bash infrastructure/scripts/<script>.sh
```

**base64 decoding:** Scripts use `base64 --decode` (long flag) instead of platform-specific short flags (`-d` on GNU/Linux, `-D` on BSD/macOS). The `--decode` flag works on both implementations.

**Package managers:** `preflight.sh` detects Darwin vs Linux. macOS uses Homebrew; Linux uses the system package manager (apt/yum). Default mode is CI-safe (no interactive prompts); pass `--interactive` for per-install confirmation.

---

## Files Reference

| File | Purpose |
|------|---------|
| `README.md` | Top-level workshop overview, prerequisites, deploy, cleanup |
| `LICENSE` | MIT-0 (AWS Workshop Studio convention) |
| `slides.md` | reveal-md slide deck (5 control objectives + 3 use cases) |
| `reveal-md.json` | reveal-md theme + transition config (verbatim from `eks-terraform-stacks`) |
| `assets/` | Excalidraw sources + exported SVGs (six diagrams) |
| `workshop/contentspec.yaml` | Workshop Studio v2 schema (region, role, content modules) |
| `workshop/content/NN-*/index.en.md` | Workshop Studio content modules |
| `infrastructure/modules/*/` | Terraform Stacks components (one per phase deliverable) |
| `infrastructure/scripts/preflight.sh` | Single entry-point: installs CLI prereqs (PREF-05) + Bedrock access (PREF-01) + service quotas (PREF-02) + IAM permissions (PREF-03) |
| `infrastructure/scripts/bootstrap.sh` | HCP Terraform org/varset/OIDC/IAM setup (PREF-04) |
| `infrastructure/scripts/excalidraw-to-svg.py` | SVG regeneration pipeline |
