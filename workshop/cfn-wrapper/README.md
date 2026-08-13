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

### The teardown build has to take the concurrency slot from the failed build

`ConcurrentBuildLimit` is **1**. When a deploy build fails, CloudFormation starts rolling back and fires the custom resource's Delete *while that build is still finalizing* — so `StartBuild` gets `AccountLimitExceededException` and the handler PUTs a `FAILED` callback. CloudFormation latches that immediately and permanently: `DELETE_FAILED` on the custom resource, `ROLLBACK_FAILED` on the stack, roughly three seconds after the build failed.

Whether the infrastructure then survives comes down to luck. The handler re-raises after responding, and CloudFormation invokes custom resources asynchronously, so Lambda's built-in async retries fire the invocation again about a minute and three minutes later. Observed live on 2026-08-10: the first retry landed 57s after the failure, by which time the slot had freed, and the teardown build ran and succeeded — the environment *was* reclaimed. But CloudFormation had already recorded the failure, so the stack stayed `ROLLBACK_FAILED` and had to be deleted by hand. Had the failing build taken longer than the retry window to finalize, every attempt would have been rejected and the EKS/RDS/VPC that Terraform created inside CodeBuild would have been stranded with nothing left to reclaim them — they are not part of the CloudFormation resource graph.

So the failure mode is: a stack that always strands itself in `ROLLBACK_FAILED`, and *sometimes* strands a live cluster with it.

The Delete path therefore calls `_free_the_build_slot` first: it lists this project's builds, stops any that are not in a terminal state, waits for the slot, and only then starts teardown — with `StartBuild` additionally retried under exponential backoff in case of a race. Stopping the in-flight build is correct on Delete in both cases it arises: during a rollback the build has already sent its `FAILED` callback, and during an operator-initiated `delete-stack` mid-deploy the in-flight deploy is moot. Whatever it had half-built is reconciled by `teardown.sh`, which sweeps by tag and well-known name rather than from state.

This costs three IAM actions beyond `StartBuild` (`ListBuildsForProject`, `BatchGetBuilds`, `StopBuild`). All four support resource-level permissions, so none of them is granted on `*` — `BatchGetBuilds`/`StopBuild` take the *build* resource type and are scoped to `build/<this-project>:*` (T-11-06).

## Timeout caveat (unverified)

CloudFormation is unblocked **only** by the buildspec's `finally` callback: with `CodeBuildCallback: true` the trigger Lambda deliberately sends no `cfnresponse`. If CodeBuild kills a build on `TimeoutInMinutes`, whether `finally` still runs is **not verified**. If it does not, the stack hangs rather than failing.

`TimeoutInMinutes` is 180 (tier-1 ~17 min + tier-2 ~15 min nominal, plus Step 7's 900s ACME gate and a repair pass in the worst case). Raising it reduces how often the ceiling is reached but does not resolve the question. If testing shows `finally` is skipped on a timeout kill, the fix is an EventBridge rule on CodeBuild state change (`FAILED`/`TIMED_OUT`/`STOPPED`) invoking a Lambda that PUTs `FAILED` to the response URL.

## Dev-account sim (manual test outside Workshop Studio)

`sim-workshop-studio.sh` in this directory runs the whole simulation in one command. It stops before each major step so you can inspect state, and the deploy runs in the background so Ctrl-C at a prompt does not kill it.

```bash
./workshop/cfn-wrapper/sim-workshop-studio.sh \
  --icr-key '<icr-entitlement-key>' \
  --mmfa-secret '<mmfa-push-secret>'

./workshop/cfn-wrapper/sim-workshop-studio.sh --status   # check on it from anywhere
```

The Vault license defaults to `~/Downloads/vault-ent.hclic`; override with `--license PATH`. All three secrets may instead come from `ICR_ENTITLEMENT_KEY`, `IVIA_MMFA_PUSH_CLIENT_SECRET` and `VAULT_ENTERPRISE_LICENSE_PATH`, which keeps them out of shell history. They reach CloudFormation through a mode-600 parameters file, never as command-line arguments — arguments are readable by every process on the machine via `ps`.

The script does, in order: preflight (credentials, tooling, license size, and that no stack already exists) → create `WSParticipantRole` with the six managed policies `contentspec.yaml` grants → `package-assets.sh` + upload under the key prefix → create the stack → poll → report the staged artifacts.

**Three things it gets right that a hand-rolled recipe usually does not**, and each one invalidates the test if wrong:

- **Region `us-east-1`.** `contentspec.yaml` pins `deployableRegions.required: [us-east-1]` with `maxAccessibleRegions: 1`.
- **`WSParticipantRole` must exist, with exactly those six policies.** `buildspec.yml`'s `aws iam put-role-policy` has no `|| true` and runs under `set -e`, so a missing role fails the build outright. And the policy set is the whole point of the security assertions: proving a role holding `SecretsManagerReadWrite` still cannot read the licensing secrets.
- **Assets live under a key prefix**, because Workshop Studio passes `{{.AssetsBucketPrefix}}` — not at the bucket root.

Teardown stays a separate, deliberate act:

```bash
aws cloudformation delete-stack --stack-name cfn-sim-atevent --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name cfn-sim-atevent --region us-east-1
aws s3 rb "s3://cfn-sim-assets-<account>-useast1" --force
```

> **Re-running:** a stack **update** does not re-run the build — `IgnoreUpdate: true` makes `handle_update` a no-op, so re-deploying over a live stack updates the template and provisions nothing while reporting success. Each test iteration is a fresh create with a delete in between; the script refuses to run against an existing stack for exactly this reason. To re-run against an already-deployed environment without disturbing the stack, use `aws codebuild start-build --project-name <CodeBuildProjectName output>`; with no `CFN_EVENT_RESPONSE_URL` the buildspec takes its dev-sim branch and sends no callback.

> The state-staging bucket the stack creates (`StateBucketName` output) is **retained** on stack delete (versioned). It holds the staged tier-1 state, the attendee-facing tier-2 artifacts under `tier2/`, and the full tier-2 state under `tier2-private/` — the last of which contains the licensing secrets in plaintext, so remove the bucket once you are done with it.
