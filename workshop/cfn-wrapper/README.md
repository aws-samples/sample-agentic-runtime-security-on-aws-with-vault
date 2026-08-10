# Workshop Studio CFN wrapper

Publishes this workshop to **AWS Workshop Studio** via the **CloudFormation → CodeBuild → Terraform** bridge, using the **S3-assets source pattern** (aligned to [jonathanmhurley/agentic-runtime-security-on-aws](https://github.com/jonathanmhurley/agentic-runtime-security-on-aws)). Hybrid model: CodeBuild pre-provisions **tier-1** (EKS foundation) **and tier-2** (Vault + IVIA) at account-provisioning time; the **attendee runs tier-3** themselves as the hands-on lesson. The same repo/scripts/HCL/content stay **fully self-paced** without Workshop Studio.

Tier 2 moved into the build so the organizer supplies the three licensing secrets **once** at stack create instead of handing them to every attendee (#21).

## Where the artifacts live

| Path | What it is |
|---|---|
| `workshop/static/cfn/bootstrap.yaml` | Production CFN template. CodeBuild + scoped exec role + Lambda custom-resource trigger + `CodeBuildCallback`, plus the three `NoEcho` licensing parameters, the CMK that encrypts them and the StateBucket policy that keeps attendees out of the full tier-2 state. Sources assets from S3 (`TerraformSourceBucket`). Wired into `contentspec.yaml` `infrastructure.cloudformationTemplates` as `static/cfn/bootstrap.yaml`. |
| `workshop/assets/buildspec/buildspec.yml` | The buildspec CodeBuild runs: install tools → `bootstrap.sh --skip-prereq-gate` → inject `acme_email` + region → assert the three secrets arrived + materialize the Vault license → `deploy-workshop.sh --tier 1` → stage tier-1 state → `deploy-workshop.sh --tier 2` → stage tier-2 state as two artifacts → grant `WSParticipantRole` EKS access → shred the license → CFN callback. |
| `workshop/assets/terraform/infrastructure/` | **Generated** (gitignored). Full `infrastructure/` tree synced by `workshop/scripts/package-assets.sh` (single source of truth stays `infrastructure/`). CodeBuild runs tier-1 from here; only tier-1 applies, the rest rides along for the scripts. |

**No git clone, no public mirror.** Workshop Studio uploads `workshop/assets/` to its per-workshop S3 bucket (`publish.sh` → `aws s3 sync ./assets s3://ws-assets-us-east-1/agentic-runtime-security-aws`); CodeBuild sources `buildspec/` + `terraform/` from there as `Source.Type=S3`.

## Proven (2026-06-29, live, since torn down)

- The bridge runs non-interactively: **tier-1 applied 183 resources in 16m38s** in a CodeBuild container; 30+ foundation checks PASS — well inside the **79-min** Workshop Studio provisioning budget.
- One non-TTY adjustment, **zero script change**: `bootstrap.sh --skip-prereq-gate` (the only `/dev/tty` read). `deploy-workshop.sh` is already non-interactive with tfvars pre-seeded.
- Local Terraform state dies with the build container → tier-1 state is **staged** (state + tfvars uploaded; attendee pulls to the local path) while all roots stay on `backend="local"` (zero HCL change).

## Teardown — `delete-stack` tears down tier-2 then tier-1

`BuildOnDelete: true` + `CodeBuildCallback: true`: CFN Delete fires a teardown build and waits for its callback. The buildspec's `CFN_EVENT_TYPE=Delete` branch:

1. **Destroys tier-2 first, while the cluster still exists** — restores the staged tier-1 tfvars/state and the full tier-2 state from `tier2-private/`, binds the three required variables via `TF_VAR_*`, and runs `terraform -chdir=services destroy`. This reconciles the IVIA/Vault PVCs (and the EBS volumes behind them) and the WRP Ingress (and its ALB). A failure here warns and continues rather than blocking the sweep.
2. **Runs `teardown.sh --post-destroy-only --yes`** — the tag + well-known-name sweep, state-independent, which removes tier-1 (EKS/RDS/VPC/KB/audit). Terraform creates that infra *inside* CodeBuild, so it is not part of the CFN resource graph and stack deletion alone would orphan it.
3. **Empties the versioned StateBucket** so CFN can delete it rather than failing on a non-empty bucket.

The ordering is the point: deleting the cluster first would strand the tier-2 AWS resources with nothing left to reconcile them.

The known risk of this design is that a delete-build which hangs blocks stack deletion, because CFN waits on the callback. The CodeBuild timeout is the intended backstop — see the timeout caveat below.

## Timeout caveat (unverified)

CloudFormation is unblocked **only** by the buildspec's `finally` callback: with `CodeBuildCallback: true` the trigger Lambda deliberately sends no `cfnresponse`. If CodeBuild kills a build on `TimeoutInMinutes`, whether `finally` still runs is **not verified**. If it does not, the stack hangs rather than failing.

`TimeoutInMinutes` is 180 (tier-1 ~17 min + tier-2 ~15 min nominal, plus Step 7's 900s ACME gate and a repair pass in the worst case). Raising it reduces how often the ceiling is reached but does not resolve the question. If testing shows `finally` is skipped on a timeout kill, the fix is an EventBridge rule on CodeBuild state change (`FAILED`/`TIMED_OUT`/`STOPPED`) invoking a Lambda that PUTs `FAILED` to the response URL.

## Dev-account sim (manual test outside Workshop Studio)

Mirrors the reference repo's manual-test recipe. Region `us-west-2`, account from `aws sts get-caller-identity`. The dev-sim uses a local bucket in the CodeBuild region (real WS exposes its own assets bucket — see the VERIFY-ON-REAL-WS note in `contentspec.yaml`).

```bash
# 0. Regenerate the assets tree (syncs infrastructure/ -> assets/terraform/, secret-leak gated)
bash workshop/scripts/package-assets.sh

# 1. Create a private SSE bucket and upload the assets (buildspec/ + terraform/) to its root
ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="cfn-sim-assets-${ACCT}-usw2"
aws s3api create-bucket --bucket "$BUCKET" --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3 sync workshop/assets/ "s3://${BUCKET}/" \
  --exclude 'cfn/*' --exclude 'terraform/infrastructure/.terraform/*'

# 2. Deploy the CFN stack pointed at the bucket (AssetsKeyPrefix empty = bucket root).
#    The three licensing parameters are REQUIRED (MinLength 1) — the stack will not
#    create without them, which is deliberate: it fails here rather than 20 minutes
#    into the build. AcmeEmail stays optional.
aws cloudformation deploy \
  --template-file workshop/static/cfn/bootstrap.yaml \
  --stack-name cfn-sim-atevent \
  --parameter-overrides \
    AcmeEmail="you@real-domain.com" \
    TerraformSourceBucket="$BUCKET" \
    IcrEntitlementKey="$(cat ~/.ibm-icr-entitlement-key)" \
    VaultEnterpriseLicense="$(cat ~/Downloads/vault-ent.hclic)" \
    IviaMmfaPushClientSecret="$(cat ~/.ivia-mmfa-push-secret)" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

# 3. Watch the CodeBuild run (stack stays CREATE_IN_PROGRESS until the callback fires)
aws logs tail /aws/codebuild/workshop-tier1 --follow --region us-west-2

# 4. Clean up: delete the stack (this now tears down tier-2 then tier-1 via the
#    delete build), then empty+delete the assets bucket.
aws cloudformation delete-stack --stack-name cfn-sim-atevent --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name cfn-sim-atevent --region us-west-2
aws s3 rb "s3://${BUCKET}" --force
```

> **Re-running:** a stack **update** does not re-run the build — `IgnoreUpdate: true` makes `handle_update` a no-op. Each test iteration is a fresh create with a delete in between. To re-run against an already-deployed environment without disturbing the stack, use `aws codebuild start-build --project-name <CodeBuildProjectName output>`; with no `CFN_EVENT_RESPONSE_URL` the buildspec takes its dev-sim branch and sends no callback.

> The state-staging bucket the stack creates (`StateBucketName` output) is **retained** on stack delete (versioned). It holds the staged tier-1 state, the attendee-facing tier-2 artifacts under `tier2/`, and the full tier-2 state under `tier2-private/` — the last of which contains the licensing secrets in plaintext, so remove the bucket once you are done with it.
