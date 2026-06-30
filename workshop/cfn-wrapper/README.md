# Workshop Studio CFN wrapper

Publishes this workshop to **AWS Workshop Studio** via the **CloudFormation → CodeBuild → Terraform** bridge, using the **S3-assets source pattern** (aligned to [jonathanmhurley/agentic-runtime-security-on-aws](https://github.com/jonathanmhurley/agentic-runtime-security-on-aws)). Hybrid model: CodeBuild pre-provisions **tier-1** (EKS foundation) at account-provisioning time; the **attendee runs tier-2/3** themselves as the hands-on lesson. The same repo/scripts/HCL/content stay **fully self-paced** without Workshop Studio.

## Where the artifacts live

| Path | What it is |
|---|---|
| `workshop/assets/cfn/bootstrap.yaml` | Production CFN template. CodeBuild + scoped exec role + Lambda custom-resource trigger + `CodeBuildCallback`. Sources assets from S3 (`TerraformSourceBucket`). Wired into `contentspec.yaml` `infrastructure.cloudformationTemplates`. |
| `workshop/assets/buildspec/buildspec.yml` | The buildspec CodeBuild runs: install tools → `bootstrap.sh --skip-prereq-gate` → inject `acme_email` + tier-2 sentinels → `deploy-workshop.sh --tier 1` → stage tier-1 state to S3 → grant `WSParticipantRole` EKS access → CFN callback. |
| `workshop/assets/terraform/infrastructure/` | **Generated** (gitignored). Full `infrastructure/` tree synced by `workshop/scripts/package-assets.sh` (single source of truth stays `infrastructure/`). CodeBuild runs tier-1 from here; only tier-1 applies, the rest rides along for the scripts. |

**No git clone, no public mirror.** Workshop Studio uploads `workshop/assets/` to its per-workshop S3 bucket (`publish.sh` → `aws s3 sync ./assets s3://ws-assets-us-east-1/agentic-runtime-security-aws`); CodeBuild sources `buildspec/` + `terraform/` from there as `Source.Type=S3`.

## Proven (2026-06-29, live, since torn down)

- The bridge runs non-interactively: **tier-1 applied 183 resources in 16m38s** in a CodeBuild container; 30+ foundation checks PASS — well inside the **79-min** Workshop Studio provisioning budget.
- One non-TTY adjustment, **zero script change**: `bootstrap.sh --skip-prereq-gate` (the only `/dev/tty` read). `deploy-workshop.sh` is already non-interactive with tfvars pre-seeded.
- Local Terraform state dies with the build container → tier-1 state is **staged** (state + tfvars uploaded; attendee pulls to the local path) while all roots stay on `backend="local"` (zero HCL change).

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

# 2. Deploy the CFN stack pointed at the bucket (AssetsKeyPrefix empty = bucket root)
aws cloudformation deploy \
  --template-file workshop/assets/cfn/bootstrap.yaml \
  --stack-name cfn-sim-atevent \
  --parameter-overrides AcmeEmail="you@real-domain.com" TerraformSourceBucket="$BUCKET" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

# 3. Watch the CodeBuild run (stack stays CREATE_IN_PROGRESS until the callback fires)
aws logs tail /aws/codebuild/workshop-tier1 --follow --region us-west-2

# 4. Clean up: delete the stack, empty+delete the assets bucket, then teardown the provisioned infra
aws cloudformation delete-stack --stack-name cfn-sim-atevent --region us-west-2
aws s3 rb "s3://${BUCKET}" --force
bash infrastructure/scripts/teardown.sh   # provisioned workshop infra (EKS etc.)
```

> The state-staging bucket the stack creates (`StateBucketName` output) is **retained** on stack delete (versioned, holds the staged tier-1 state). Remove it manually after teardown if you don't need it.
