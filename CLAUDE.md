# Project Instructions — agentic-runtime-security-aws

## Scope constraints (final, do not relitigate)

- **Karpenter is OUT of scope.** EKS cluster runs with managed node group only. No Karpenter NodePool, EC2NodeClass, controller install, or Karpenter Blueprints reference. Global `~/.claude/CLAUDE.md` mandate to use Karpenter Blueprints does NOT apply to this project.
- **ArgoCD is OUT of scope.** No GitOps controller. Deploys are Helm-direct or Terraform Stacks. No `argo-cd` Helm release, no Application/AppProject CRDs.
- **Bedrock LLM = Amazon Nova Pro** via cross-region inference profile id `us.amazon.nova-pro-v1:0` (NOT the bare `amazon.nova-pro-v1:0` — Bedrock rejects it for on-demand throughput). **Embedding model = Amazon Nova 2 Multimodal Embeddings** (`amazon.nova-2-multimodal-embeddings-v1:0`, direct model ARN, no CRIS). The embedding model is **us-east-1 only** — KB components (AOSS, Bedrock KB, S3 corpus/multimodal) deploy to us-east-1 via `provider.aws.kb`; everything else stays in us-west-2.
- **Canonical region contract**: no string literal `us-west-2` or `us-east-1` outside `infrastructure/deployments.tfdeploy.hcl`. All other modules interpolate `var.region` (or `var.kb_region` for KB components).

## Workshop content conventions

- Verification commands belong IN the workshop walkthrough markdown as steps attendees execute (`kubectl get nodes`, `aws eks describe-cluster`, `aws rds describe-db-instances`, `aws bedrock-agent get-knowledge-base`, etc.) — modeled on the eks-terraform-stacks workshop pattern. NOT something Claude runs.
- No terminal-color helper snippets in `workshop/content/**` (palette/sanity-check examples). Runtime fixes only.
- Workshop Studio v2 contentspec (no `serviceQuotas` field — quota provisioning is admin-UI out-of-band).

## Code conventions

- **Every script MUST be idempotent and safe to re-run end-to-end — no exceptions.** This is non-negotiable and applies especially to `configure-workshop.sh` and the whole deploy flow: a second `bash configure-workshop.sh` (or any deploy/build/seed script) must succeed without errors, manual cleanup, or "already exists" failures, skipping or re-converging already-done work. New steps you add inherit this rule — design re-runnability in from the start, never as an afterthought. Provide `--skip-*` flags for slow re-runnable steps where it helps.
- Atomic commits per logical change; explicit `git add <path>` (never `git add .` / `-A`).
- Terraform fmt clean; modules carry README.md as authoritative module documentation.
- Helm provider pinned **2.17** (NOT 3.x — Pitfall H1).
- opensearch-project/opensearch provider pinned **EXACT `= 2.2.0`** (Bedrock KB index creation).
- **Terraform CLI minimum: 1.10** for the workshop's Stacks deploy (Stacks features `terraform stacks plan/apply` require 1.10+). Enforced by `infrastructure/scripts/check-prerequisites.sh` via the `TERRAFORM_MIN_VERSION` constant + `version_gte` helper.

## Don't

- Don't add `(with Karpenter)`, `argo-cd`, or `karpenter` references to any module, content, or comment.
- Don't ask the user to re-confirm the constraints above. They are settled.
- **Don't speculate or assume.** Never add config keys, YAML parameters, or API values that are not confirmed in official IBM docs, IBM GitHub samples (`IBM-Security/verify-access-oidc-provider-resources`), or verified on the live system. Speculative config has broken working flows (e.g., adding unvalidated `token_exchange` YAML keys broke a working CIBA poll). If unsure, research first — don't guess.
- **Never modify files the user didn't ask to change.** When committing, only include files related to the current task. If there are unrelated modified files in the working tree, flag them — don't silently commit or "fix" them.
