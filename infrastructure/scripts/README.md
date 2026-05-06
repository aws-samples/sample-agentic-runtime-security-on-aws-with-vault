# Workshop Scripts

Scripts for bootstrapping, pre-flight verification, and SVG regeneration for the Agentic Runtime Security on AWS workshop. The set mirrors `~/git-repos/eks-terraform-stacks/infrastructure/scripts/` and adds the workshop-specific pre-flight checks (Bedrock model access, AWS service quotas, IAM permissions) plus an installer that auto-installs every required CLI tool so attendees do not install anything manually.

## Script Inventory

| Script | Used By | Purpose | Requirement |
|--------|---------|---------|-------------|
| `install-prereqs.sh` | Workshop user | Auto-installs kubectl 1.33.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws v2, jq, yq on macOS or Linux (CI-safe, no interactive prompts) | PREF-05 (companion) |
| `check-bedrock-access.sh` | Workshop user | Verifies `anthropic.claude-sonnet-4-6` model access in `us-west-2` and emits remediation if access is OFF | PREF-01 |
| `check-quotas.sh` | Workshop user | Verifies EC2 standard vCPUs (32), VPC EIPs (6), RDS DB instances per region (1), and OpenSearch Serverless OCUs (2 indexing + 2 search) | PREF-02 |
| `check-permissions.sh` | Workshop user | Verifies the calling principal has IAM permissions sufficient for Stacks deployment | PREF-03 |
| `bootstrap.sh` | Workshop user | Single-command HCP Terraform setup: project + variable set + OIDC trust + IAM role + Stacks deployment seeding (idempotent) | PREF-04 |
| `excalidraw-to-svg.py` | Workshop user, content authors | Converts the six Excalidraw sources in `assets/` to SVG (single-source-of-truth pipeline; SVGs are committed but regenerable) | SCAF-03 |

## Workshop User Flow

```bash
# 1. Install all CLI tools (one-time, before pre-flight checks)
./infrastructure/scripts/install-prereqs.sh

# 2. Pre-flight verification (all four scripts continue through failures
#    and emit a single consolidated summary at the end)
./infrastructure/scripts/check-bedrock-access.sh
./infrastructure/scripts/check-quotas.sh
./infrastructure/scripts/check-permissions.sh

# 3. Bootstrap HCP Terraform (creates project + variable set + OIDC + IAM)
./infrastructure/scripts/bootstrap.sh <HCP_ORG>
```

## Output Conventions

Each pre-flight script emits colored terminal output with `✓ PASS` / `✗ FAIL` / `⚠ WARN` markers, indented detail under each check, and a single consolidated summary block at the end listing every failure with full inline copy-paste remediation (the exact AWS Console path or `aws` CLI command). No "see external doc" indirection. All scripts are CI-safe (no interactive prompts) and continue running through failures rather than fail-fast — so a single run surfaces all blockers at once.

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
