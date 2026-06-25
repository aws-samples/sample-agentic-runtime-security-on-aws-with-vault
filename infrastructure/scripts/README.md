# Workshop Scripts

Bootstrapping, end-to-end orchestration, per-component verification, and teardown for the Agentic Runtime Security on AWS workshop.

## Script Inventory

| Script | Used By | Purpose | Requirement |
|--------|---------|---------|-------------|
| `check-prerequisites.sh` | Workshop user, `workshop-e2e.sh` | Single entry-point: installs CLI tools (kubectl 1.34.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws v2, jq, yq), then verifies Bedrock model access, AWS service quotas (EC2 vCPU + EIP + RDS + AOSS OCU indexing/search), and IAM permissions for the workshop bootstrap. Mirrors `eks-terraform-stacks/infrastructure/scripts/check-prerequisites.sh` (same name, broader workshop-specific checks) | PREF-01, PREF-02, PREF-03, PREF-05 |
| `bootstrap.sh` | Workshop user | Single-command local bootstrap: ensures EC2 Spot service-linked role, resolves admin principal ARN, generates `infrastructure/terraform.tfvars`, and runs `terraform init` (local state). Prompts to confirm `check-prerequisites.sh` has been run; pass `--skip-prereq-gate` to bypass (used automatically by `workshop-e2e.sh`, which runs prereqs in Phase 0). | PREF-04 |
| `common-checks.sh` | Sourced library (not invoked directly) | Shared bash helpers — color constants, ✓/✗/⚠ unicode markers, FAILURES[] accumulator, `confirm()` y/N prompt, opt-in EXIT-trap summary | (library) |
| `resolve-region.sh` | Sourced library (not invoked directly) | Shared `resolve_region()` helper — resolves region from CLI arg → `$AWS_REGION` → `infrastructure/terraform.tfvars`. Sets `RESOLVED_REGION`. Honors the canonical-region contract (no `us-west-2` string literals) | (library) |
| `test-eks.sh` | Workshop user, `test-foundation.sh`, `workshop-e2e.sh` | Verifies workshop EKS cluster: status ACTIVE, ≥2 Ready nodes, 5 managed addons (vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver) ACTIVE, access entry present | — |
| `test-rds.sh` | Workshop user, `test-foundation.sh`, `workshop-e2e.sh` | Verifies workshop RDS PostgreSQL: status available, engine postgres 17.x, MasterUserSecret present, parameter group has `pgaudit` in `shared_preload_libraries` and `pgaudit.log` set, storage encrypted | — |
| `test-bedrock-kb.sh` | Workshop user, `test-foundation.sh`, `workshop-e2e.sh` | Verifies Bedrock Knowledge Base: KB status ACTIVE, 3 data sources (hr/customers/finance) AVAILABLE, retrieval smoke query per data source, AOSS collection ACTIVE | — |
| `test-foundation.sh` | Workshop user, `workshop-e2e.sh` | Wraps `test-eks.sh` + `test-rds.sh` + `test-bedrock-kb.sh`. Aggregates pass/fail. Exits non-zero if any component fails | — |
| `teardown.sh` | Admin/presenter, `workshop-e2e.sh` | Single-file workshop nuke. Default: K8s drain + terraform destroy + AWS resource sweep (tag-scoped). Flags: `--aws-only` (just AWS resources), `--post-destroy-only` (sweep only, skip terraform destroy), `--dry-run`, `--help` | — |
| `e2e-validate.sh` | Admin/presenter | Lints all `*.sh`: shebang consistency, `bash -n` syntax, optional shellcheck, no bash-4-only constructs (stock macOS bash 3.2 compat), no `base64 -d` usage. No deployment | — |
| `workshop-e2e.sh` | Admin/presenter | Full lifecycle orchestrator (Phase 0–8). Single-command deploy + verify + teardown with local Terraform state. | — |
| `excalidraw-to-svg.py` | Workshop user, content authors | Converts the six Excalidraw sources in `assets/` to SVG (single-source-of-truth pipeline) | SCAF-03 |
| `install-git-hooks.sh` | Maintainer (one-time, post-clone) | Symlinks `infrastructure/git-hooks/*` into `.git/hooks/`. Enables the `post-merge` hook that auto-runs `instruqt/scripts/push.sh` when a merge to `main` touches `instruqt/**` (GHE org has Actions disabled, so the local hook replaces CI for Instruqt sync) | — |
| `deploy-workshop.sh` | Workshop user | Tier-by-tier deploy orchestrator (`--tier 1\|2\|3`). Flags: `--image-source <ghcr\|ecr>` (default `ghcr`), `--ghcr-registry-base <base>` (default `ghcr.io/sharepointoscar`), `--skip-infra`, `--skip-build`, `--skip-vault-init`, `--skip-acme`. In `ghcr` mode: no build, no ECR, no deployment roll. In `ecr` mode: builds via `build-*.sh`, pushes to ECR, rolls deployments to pull `:latest`. | — |
| `build-images.sh` | `deploy-workshop.sh` (`--image-source ecr`), self-paced attendee | Top-level build coordinator — calls `build-uc1-agent.sh`, `build-banking-app.sh`, `build-uc3-agent.sh` in sequence. Used only in `ecr` mode. | — |
| `build-uc1-agent.sh` | `build-images.sh`, self-paced attendee | Builds the Use Case 1 agent image from `infrastructure/modules/uc1_agent/agent/Dockerfile` (`--platform linux/amd64`) and pushes to the attendee's ECR. Used only in `ecr` mode. | — |
| `build-banking-app.sh` | `build-images.sh`, self-paced attendee | Builds three banking-app images (ui / agent / mcp) including the host-side MCP `tsc` compile (`--platform linux/amd64`) and pushes to the attendee's ECR. Used only in `ecr` mode. | — |
| `build-uc3-agent.sh` | `build-images.sh`, self-paced attendee | Builds the Use Case 3 agent image (`--platform linux/amd64`) and pushes to the attendee's ECR. Used only in `ecr` mode. | — |
| `publish-images.sh` | Maintainer only (NOT in the attendee path) | Builds the workshop images (`--platform linux/amd64`) and pushes them to the configured public GHCR base (default `ghcr.io/sharepointoscar`, override via `GHCR_REGISTRY_BASE` env or `--registry-base`). Default publishes all five at `:v1`. `--image <name>` (repeatable: `uc1-agent`, `banking-ui`, `banking-agent`, `banking-mcp`, `uc3-agent`) restricts to a subset; `--version <tag>` (default `v1`, **requires `--image`**) bumps only that image — so unchanged images never get a meaningless new tag (e.g. `--image banking-ui --version v2`). Inlines its own build (does NOT call `build-*.sh`). Requires a `write:packages` PAT via `GHCR_PAT` env or `gh auth token`. Idempotent, `--dry-run`. | — |

## Image source: GHCR default vs ECR opt-in

The workshop supports two image-source modes controlled by `deploy-workshop.sh --image-source <ghcr|ecr>` (default `ghcr`). The mode is persisted by `bootstrap.sh` into `infrastructure/terraform.tfvars` so partial re-runs (`--tier N`) hold the mode automatically.

### Default mode: `ghcr` (anonymous pull, no build, no container runtime)

`deploy-workshop.sh` (no flags) pulls the five pre-built public images from GHCR anonymously at pod start:

| Image | GHCR package |
|-------|-------------|
| Use Case 1 agent | `<ghcr_registry_base>/workshop-uc1-agent:v1` |
| Banking app UI | `<ghcr_registry_base>/workshop-banking-app-ui:v1` |
| Banking app agent | `<ghcr_registry_base>/workshop-banking-app-agent:v1` |
| Banking app MCP | `<ghcr_registry_base>/workshop-banking-app-mcp:v1` |
| Use Case 3 agent | `<ghcr_registry_base>/workshop-uc3-agent:v1` |

`ghcr_registry_base` defaults to `ghcr.io/sharepointoscar`. No ECR repos provisioned, no `aws ecr` call, no container runtime required, no deployment roll.

To repoint the GHCR base (e.g., fork to your own namespace), pass `--ghcr-registry-base ghcr.io/<you>` — this cascades `ghcr_registry_base` into the tier-3 Terraform apply. The publish base (`publish-images.sh --registry-base`) and the consume base (`deploy-workshop.sh --ghcr-registry-base`) must match; pointing consume at an empty or private base yields `ImagePullBackOff`.

### Self-paced opt-in: `ecr` (local build + push to your ECR)

`deploy-workshop.sh --image-source ecr` runs the full local-build → ECR flow: `bootstrap.sh` stamps your `<account>/<region>` ECR image URIs into the tier-3 tfvars, Terraform provisions the ECR repos, `build-images.sh` builds the five images via `build-uc1-agent.sh` / `build-banking-app.sh` / `build-uc3-agent.sh` and pushes them to your ECR, and the deployments roll to pull the newly pushed `:latest` images. Requires a running container runtime (Docker or Podman — see [Self-paced: build images locally](https://github.com/Oscar-Medina/agentic-runtime-security-aws/blob/main/workshop/content/20-prerequisites/23-pre-flight-checks/index.en.md#self-paced-build-images-locally---image-source-ecr) in the workshop pre-flight page).

### Maintainer-only: publish to GHCR

`publish-images.sh` is the maintainer-only release path. It builds all five images with `--platform linux/amd64` and pushes them to the configured public GHCR namespace. It inlines its own build — it does NOT call `build-*.sh`. The GHCR owner for `docker login` is derived from the registry base. Run once per release and set each of the five packages Public via the GitHub web UI after pushing (there is no REST API for container-package visibility).

```bash
# Add the write:packages scope to your GitHub CLI token (one-time)
gh auth refresh -h github.com -s write:packages

# Publish to the default namespace (ghcr.io/sharepointoscar)
bash infrastructure/scripts/publish-images.sh

# Publish to a fork namespace
bash infrastructure/scripts/publish-images.sh --registry-base ghcr.io/<you>
```

## Workshop User Flow

```bash
# 1. Pre-flight (installs CLI tools + runs all checks in one shot)
./infrastructure/scripts/check-prerequisites.sh

# 2. Bootstrap (ensures EC2 Spot SLR + generates terraform.tfvars)
./infrastructure/scripts/bootstrap.sh

# 3. Deploy foundation
cd infrastructure && terraform apply

# 4. Verify foundation
./infrastructure/scripts/test-foundation.sh \
    --cluster-name agentic-runtime-usw2 \
    --db-instance-id <db-id> \
    --knowledge-base-id <kb-id>
# Each of test-eks.sh / test-rds.sh / test-bedrock-kb.sh can also be run individually.
```

## Per-Component Test Flags

```bash
./test-eks.sh        --cluster-name <name>         [--region <region>]
./test-rds.sh        --db-instance-id <id>         [--region <region>]
./test-bedrock-kb.sh --knowledge-base-id <kb_id>   [--region <region>]
./test-foundation.sh --cluster-name <name> --db-instance-id <id> --knowledge-base-id <kb_id> [--region <region>]
```

Region resolution order: `--region` arg → `$AWS_REGION` env var → `region` value in `infrastructure/terraform.tfvars`. Fail-fast if none resolve.

`test-foundation.sh` also reads `WORKSHOP_CLUSTER_NAME` / `WORKSHOP_DB_INSTANCE_ID` / `WORKSHOP_KB_ID` env vars as fallbacks for missing flags.

## Admin / Presenter Flow

### `workshop-e2e.sh`

Single-command orchestrator. Phase model:

| Phase | What it does |
|-------|--------------|
| 0 | Prerequisites — calls `check-prerequisites.sh` |
| 1 | Bootstrap — calls `bootstrap.sh --skip-prereq-gate` (Phase 0 already ran prereqs) |
| 2 | Foundation deploy — `terraform apply` (local state) |
| 3 | Configure kubectl — single deployment `usw2` (region from `terraform.tfvars`) |
| 4 | Foundation verify — calls `test-foundation.sh` |
| 5 | Identity (IVIA) — verify IVIA pods + OIDC discovery |
| 6 | Vault — init + configure (local via port-forward) |
| 7 | Use cases (UC1/UC2/UC3) — build images, deploy, verify |
| 8 | Teardown — calls `teardown.sh` (unless `--skip-teardown`) |

```bash
# Full lifecycle: bootstrap → deploy → verify → teardown
./infrastructure/scripts/workshop-e2e.sh

# Deploy and leave running for inspection
./infrastructure/scripts/workshop-e2e.sh --interactive --skip-teardown

# Destroy everything (foundation + dangling AWS resources)
./infrastructure/scripts/workshop-e2e.sh --nuke

# Cleanup only (foundation already destroyed; sweep dangling AWS resources)
./infrastructure/scripts/workshop-e2e.sh --cleanup-only
```

### All `workshop-e2e.sh` flags

| Flag | Purpose |
|------|---------|
| `--interactive` | Pause between phases for manual verification |
| `--skip-teardown` | Leave deployment running after verification |
| `--teardown-only` | Skip deployment, run teardown only |
| `--nuke` | Destroy everything: foundation + dangling AWS resources |
| `--cleanup-only` | Skip terraform destroy; sweep dangling AWS resources only |
| `--skip-addons` | No-op for now (reserved for Phase 3+ controllers) |
| `--dry-run` | Preview what would be done without executing |
| `--start-from PHASE` | Skip phases before PHASE (prerequisites, bootstrap, foundation, ...) |

### `teardown.sh`

Single nuke command — wipes everything the workshop provisioned.

```bash
./teardown.sh                    # Full: terraform destroy + AWS sweep
./teardown.sh --aws-only         # Just AWS resources (K8s drain + tag-scoped sweep)
./teardown.sh --post-destroy-only  # Skip terraform destroy, run full orphan sweep
./teardown.sh --dry-run          # Preview without executing
./teardown.sh --help             # Usage
```

Discovery: `Workshop=agentic-runtime-security` tag + the well-known names this workshop uses (cluster `agentic-runtime-usw2`, S3 buckets prefixed `workshop-kb-corpus`, Glue DB `workshop_logs`, Athena workgroup `workshop`, CW log groups `/workshop/*`, RDS instance `<cluster>-pg`).

Sweeps EKS pod-identity associations, node groups, cluster, RDS, AOSS, S3, Bedrock KB, Glue/Athena, CW log groups, KMS, IAM roles, EKS cluster IAM OIDC, and per-VPC: ELBs, endpoints, ENIs, SGs, NAT/EIP/IGW/subnets/RTs/VPC.

### `e2e-validate.sh`

Runs offline lint on every script in this directory. Used by admins before committing script changes:

```bash
./infrastructure/scripts/e2e-validate.sh
```

Phases: shebang consistency, `bash -n` syntax, optional shellcheck (skipped if not installed), cross-platform compatibility (no `base64 -d`).

## Output Conventions

`check-prerequisites.sh` and `test-*.sh` emit colored terminal output with `✓ PASS` / `✗ FAIL` / `⚠ WARN` markers via the shared `common-checks.sh` library, plus a single consolidated summary block at the end listing every failure with full inline copy-paste remediation. Default mode is non-interactive (no prompts) so it is CI-safe / Workshop Studio attendee-VM-safe out of the box.

### Phase 07.8 — Trusted TLS Cert (Let's Encrypt + nip.io)

`deploy-workshop.sh` Step 4 provisions a publicly trusted Let's Encrypt
certificate for the workshop ALB so attendees see a lock icon — no
"click through self-signed warning" step. The cert is bound to two nip.io
FQDNs (`wrp.<DEPLOY_ID>.<ALB_IP_DASHED>.nip.io` for the IVIA WRP,
`banking.<DEPLOY_ID>.<ALB_IP_DASHED>.nip.io` for the banking-UI), both
fronted by the same shared ALB (Plan 02's `workshop-acme` IngressGroup).
The cert is issued by the `letsencrypt-prod` cert-manager `ClusterIssuer`
(Plan 03), wait-confirmed `Ready=true`, and bootstrap-imported into ACM at
the stable ARN (`output "tls_certificate_arn"`). The ARN is preserved
across LE renewals via `lifecycle.ignore_changes` on
`aws_acm_certificate.workshop_tls` (Plan 02, D-10). A cluster-internal
CronJob re-syncs the LE Secret into ACM every 6h (Plan 03).

#### `--skip-acme` flag

Skip Step 4 (ACME cert issuance + ACM first-sync). Use when:

- cert-manager has already issued a valid Let's Encrypt cert for the
  current cluster's nip.io FQDNs (`kubectl get certificate -n cert-manager
  workshop-le-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`
  returns `True`).
- The ACM cert at the workshop's stable ARN already has
  `Issuer: CN=R3,O=Let's Encrypt` (`aws acm describe-certificate
  --certificate-arn $STABLE_ACM_ARN --query 'Certificate.Issuer'`).
- You are iterating on a downstream step (Vault config, image build) and
  don't need to re-issue or re-import the cert.

When set, Step 4 short-circuits with a single `print_info "Step 4: ACME
skipped (--skip-acme)"` and `return 0` from `_run_acme_step()` — no
cluster mutation, no AWS call, no `.acme-state` write, no `terraform
apply -target=module.ivia`. Steps 5–8 still run.

#### Idempotency floor (D-12)

A second `bash deploy-workshop.sh` (without any flags) exits 0 with:

- NO Let's Encrypt re-issuance request (the existing cert is still valid).
- NO `aws acm import-certificate` invocation (the ARN already serves LE).
- NO `terraform apply -target=module.ivia` re-run that would flip
  `wrp_effective_host` (the value in `.acme-state` is unchanged).
- A working browser + mobile trust chain (lock icon on every page; IBM
  Verify accepts the cert without a trust-override prompt).

Mechanism: Step 4 begins with `aws acm describe-certificate
--certificate-arn $STABLE_ACM_ARN --query 'Certificate.Issuer' --output
text 2>/dev/null | grep -q "Let's Encrypt"` — when this returns 0, the
function emits `print_pass` and `return 0` before any mutating call. This
satisfies the project-wide rule that every script in this directory is
safe to re-run end-to-end (see `Code conventions` in `CLAUDE.md`).

#### `.acme-state` file

`infrastructure/.acme-state` (gitignored — see `infrastructure/.gitignore`)
records the deploy-id and nip.io FQDNs for the current deploy. It is a
shell-sourceable `KEY=value` file written by Step 4 with six entries:
`DEPLOY_ID`, `ALB_IP`, `ALB_IP_DASHED`, `NIP_FQDN_WRP`, `NIP_FQDN_BANKING`,
`STABLE_ACM_ARN`. Step 4 sources the file at start so the DEPLOY_ID is
preserved across reruns (the nip.io FQDNs stay stable — required so the
LE cert's `dnsNames` keep matching). Consumers:

- `verify-tls.sh` reads it for the `arn-stable`, `idempotent-rerun`, and
  `skip-acme-honored` behavioral checks.
- Workshop content pages tell attendees: "look for `NIP_FQDN_WRP` or
  `NIP_FQDN_BANKING` printed at the end of `bash
  infrastructure/scripts/deploy-workshop.sh`, or read them back from
  `infrastructure/.acme-state`."

To force fresh cert issuance and a new DEPLOY_ID (e.g. after a
teardown+redeploy that rotated the ALB IP), delete the file before
running `deploy-workshop.sh`:

```bash
rm -f infrastructure/.acme-state
bash infrastructure/scripts/deploy-workshop.sh
```

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
