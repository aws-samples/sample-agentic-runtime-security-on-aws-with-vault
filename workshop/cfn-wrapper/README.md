# Workshop Studio CFN wrapper — sim scaffolding

Reusable scaffolding from the **CloudFormation-wrapper spike** ([issue #46](https://github.ibm.com/Oscar-Medina/agentic-runtime-security-aws/issues/46)) for publishing this workshop to **AWS Workshop Studio**. This proved, on a live dev account, that a CloudFormation→CodeBuild→Terraform bridge can run the deploy non-interactively.

> **Status: PAUSED** pending the AWS Workshop Studio team's answer on attendee credentials. See issue #46 for the full question set, the **hybrid** direction, and the **dual-path** design.

## What was proven (2026-06-29, live, since torn down)

- The bridge works non-interactively: **tier-1 applied 183 resources in 16m38s** inside a CodeBuild container; 30+ foundation checks PASS. Fits the **79-min** Workshop Studio provisioning budget with wide margin.
- One non-TTY adjustment, **zero script change**: `bootstrap.sh --skip-prereq-gate` (the only `/dev/tty` read). `deploy-workshop.sh` is already non-interactive when tfvars are pre-seeded.
- **Local Terraform state dies with the build container** → for the hybrid, tier-1 state is staged (upload state + tfvars, attendee pulls to the local path) while all roots stay on `backend="local"` (zero HCL change).

## Direction (hybrid + dual-path)

CodeBuild pre-provisions only the slow **tier-1** (EKS) at account-provisioning time; the **attendee runs tier-2/3** themselves as the hands-on lesson. The workshop must also stay **fully self-paced without Workshop Studio** — same repo/scripts/HCL/content serve both. This `buildspec.yml` is the *full-deploy* engine-test version; the hybrid will trim it to `bootstrap.sh --skip-prereq-gate` + `deploy-workshop.sh --tier 1` + tier-1 state staging + an attendee EKS access entry.

## Files

| File | What it is |
|---|---|
| `buildspec.yml` | CodeBuild buildspec: install tools → bootstrap (`--skip-prereq-gate`) → inject 3 secrets from SSM → deploy tier 1→2→3 → verify (foundation, vault, uc1, uc3 `--bypass`) after the full deploy |
| `project.json` | CodeBuild project definition (S3 source, `aws/codebuild/standard:7.0`, no privileged mode for ghcr, CloudWatch logs). References the throwaway role/bucket by name — regenerate per the recipe |
| `trust.json` | IAM trust policy for the CodeBuild service role |

The eventual production template (`cfn_bootstrap.yml`) will live in `workshop/static/` per the contentspec `infrastructure.cloudformationTemplates` schema.

## Re-run recipe (recreate the throwaway sim)

All resources are `cfn-sim-*` prefixed and deletable after. Region `us-west-2`, account from `aws sts get-caller-identity`.

1. **Secrets → SSM SecureString** (read from local tfvars, no echo): `/cfn-sim/acme_email` (String), `/cfn-sim/icr_entitlement_key` + `/cfn-sim/ivia_mmfa_push_client_secret` (SecureString).
2. **Source zip → S3**: zip `infrastructure/` excluding `*/.terraform/*`, `*.tfstate*`, the 4 real `terraform.tfvars` (keep `.tfvars.example` + `.terraform.lock.hcl`); upload to a private SSE bucket `cfn-sim-source-<acct>-usw2`. The buildspec runs `bootstrap.sh` which reseeds tfvars from `.example`, then injects the 3 secrets.
3. **IAM role** `cfn-sim-codebuild-role` (trust = `trust.json`, attach `AdministratorAccess` — sim-only broad; the real wrapper scopes to tier-1 + bootstrap).
4. **Project**: regenerate `project.json` embedding the buildspec via `jq -n --rawfile bs buildspec.yml ...`, then `aws codebuild create-project --cli-input-json file://project.json`.
5. **Run**: `aws codebuild start-build --project-name cfn-sim-deploy`; tail with `aws logs tail /cfn-sim/deploy --follow`.
6. **Clean up**: delete the project, role (detach policy first), SSM params, bucket (`--force`), log group. Then `teardown.sh --aws-only --yes` for the provisioned workshop infra.
