# Workshop Scripts

Scripts for bootstrapping, pre-flight verification, and SVG regeneration for the Agentic Runtime Security on AWS workshop.

## Script Inventory

| Script | Used By | Purpose | Requirement |
|--------|---------|---------|-------------|
| `preflight.sh` | Workshop user | Single entry-point: installs CLI tools (kubectl 1.33.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws v2, jq, yq), then verifies Bedrock model access, AWS service quotas (EC2 vCPU + EIP + RDS + AOSS OCU indexing/search), and IAM permissions for HCP Stacks bootstrap | PREF-01, PREF-02, PREF-03, PREF-05 |
| `bootstrap.sh` | Workshop user | Single-command HCP Terraform setup: project + variable set + OIDC trust + IAM role + Stacks deployment seeding (idempotent). Prompts at the top to confirm `preflight.sh` has been run | PREF-04 |
| `common-checks.sh` | Sourced library (not invoked directly) | Shared bash helpers — color constants, ✓/✗/⚠ unicode markers, FAILURES[] accumulator, `confirm()` y/N prompt, opt-in EXIT-trap summary | (library) |
| `excalidraw-to-svg.py` | Workshop user, content authors | Converts the six Excalidraw sources in `assets/` to SVG (single-source-of-truth pipeline; SVGs are committed but regenerable) | SCAF-03 |

## Workshop User Flow

```bash
# 1. Pre-flight (installs CLI tools + runs all checks in one shot)
./infrastructure/scripts/preflight.sh

# 2. Bootstrap HCP Terraform (creates project + variable set + OIDC + IAM)
./infrastructure/scripts/bootstrap.sh <HCP_ORG>
```

`preflight.sh` flags:
  - `./preflight.sh` — default: auto-install + run all checks straight through (no prompts)
  - `./preflight.sh --interactive` — prompt before each install AND before each check section
  - `./preflight.sh --dry-run` — print install plan without executing
  - `./preflight.sh --help` — usage

`bootstrap.sh` flags:
  - `./bootstrap.sh <HCP_ORG>` — interactive: prompts to confirm `preflight.sh` was run, then 7-step orchestration
  - `./bootstrap.sh <HCP_ORG> --dry-run` — print the 8 step headers (Step 0 free-tier detect + Steps 1-7) without executing; SKIPS the prereq-gate prompt
  - `./bootstrap.sh --help` — usage

## Output Conventions

`preflight.sh` emits colored terminal output with `✓ PASS` / `✗ FAIL` / `⚠ WARN` markers, indented detail under each check, and a single consolidated summary block at the end listing every failure with full inline copy-paste remediation (the exact AWS Console path or `aws` CLI command). No "see external doc" indirection. Default mode is non-interactive (no prompts) so it is CI-safe / Workshop Studio attendee-VM-safe out of the box.

## SVG Regeneration

```bash
python3 infrastructure/scripts/excalidraw-to-svg.py
```

Regenerates all six SVGs in `assets/` from their `.excalidraw` sources:

1. Overall reference architecture
2. UC1 flow
3. UC2 OAuth flow
4. UC3 CIBA flow
5. Audit correlation (combined sequence + log-stores layout)
6. Verify+Vault responsibility split (workshop-native redraw of SKO Slide 13)

SVGs are committed to `assets/` so the workshop site builds without requiring the toolchain, but every SVG is regenerable from its source via the single command above.
