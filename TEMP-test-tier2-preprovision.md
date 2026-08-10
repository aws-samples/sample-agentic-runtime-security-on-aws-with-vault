# TEMP — Testing Tier-2 pre-provisioning (issue #21)

Scratch file for testing the `feat/21-tier2-preprovision-codebuild` branch. Delete when done.

---

## Before you start

**The only things you must supply yourself are the three secret values.** Everything else — the participant role, the assets bucket, the stack — is created by the steps below.

| Need | Check |
|---|---|
| Vault Enterprise `.hclic` on disk | `wc -c ~/Downloads/vault-ent.hclic` → non-zero and under 4096 |
| IBM Container Registry entitlement key | have it to hand |
| IBM Verify MMFA push client secret | have it to hand |

Already confirmed on this machine, no action needed: you are on `feat/21-tier2-preprovision-codebuild`; AWS credentials resolve to account `865855451418`; `terraform`, `aws`, `jq`, `kubectl`, `rsync` and `rsvg-convert` are all installed; and `package-assets.sh` runs clean with every leak gate passing.

**You do NOT need Docker or Podman.** CodeBuild builds the Use Case images in privileged mode — that is a self-paced requirement, not an at-an-event one.

### Clear the stale state from the environment you tore down

`infrastructure/` still holds `terraform.tfstate`, `services/terraform.tfstate`, `workloads/terraform.tfstate` and three `terraform.tfvars` files dated 2026-08-04. They are gitignored and `package-assets.sh` strips them from the assets tree, so **they cannot affect the CodeBuild run**. They matter only in Part 4, where you walk page 31 as an attendee: if a state pull fails you would silently be looking at August's state instead of noticing.

**Already done** — see the note below. If you ever need to repeat it, move them aside **preserving the directory structure**. A flat `mv` of all three into one directory silently overwrites them, because all three roots name their state file `terraform.tfstate`:

```bash
mkdir -p /tmp/old-workshop-state
rsync -a --remove-source-files --include='*/' \
  --include='terraform.tfstate' --include='terraform.tfstate.backup' --include='terraform.tfvars' \
  --exclude='*' infrastructure/ /tmp/old-workshop-state/
find /tmp/old-workshop-state -type f
```

Keep `infrastructure/terraform.tfvars` — `bootstrap.sh` reseeds it anyway, and page 31 overwrites it from S3.

`~/vault-init.json` is already absent, so there is no stale Vault root token to confuse things.

---

## Part 0 — How the licensing secrets actually get supplied

**Short answer: you never share them with attendees. You paste them once, into the event.**

The three values are CloudFormation parameters on the stack Workshop Studio deploys per attendee account:

| Parameter | What it is | Required |
|---|---|---|
| `VaultEnterpriseLicense` | The **contents** of the `.hclic` file, not a path | yes |
| `IcrEntitlementKey` | IBM Container Registry entitlement key | yes |
| `IviaMmfaPushClientSecret` | IBM Verify MMFA push credential | yes |

They are declared in `workshop/contentspec.yaml` under `infrastructure.cloudformationTemplates[0].parameters`, which is what makes Workshop Studio present them at event-creation time — the same mechanism `AcmeEmail` already uses. All three are `NoEcho`, so they are not echoed back in the console or returned by `describe-stacks`.

**At a real event:** set the three values when you create the Workshop Studio event, alongside `AcmeEmail`. For the Vault license, open the `.hclic` and paste its full contents as the parameter value.

> **VERIFY-ON-REAL-WS:** that Workshop Studio's event-creation UI accepts multi-hundred-character `NoEcho` parameter values without truncation. `AcmeEmail` is the only `NoEcho` parameter proven on a real event so far, and it is short.

**Check the license fits before you start.** CloudFormation caps a `String` parameter at 4096 bytes:

```bash
wc -c ~/Downloads/vault-ent.hclic
```

Expected: comfortably under `4096`. If it is over, stop — the parameter approach will not work and we need a different delivery path.

**Where they go from there:** stack → Secrets Manager (encrypted with a CMK created by the stack, with an explicit `Deny` on `WSParticipantRole`) → CodeBuild as `SECRETS_MANAGER`-typed env vars → Terraform. The Vault license is written to a temp file for the deploy script and shredded at the end of the build. Attendees are denied on the key, so `GetSecretValue` fails for them even though their role carries `SecretsManagerReadWrite`.

---

## Part 1 — Simulation setup — ALREADY DONE

All of Part 1 has been run for you. It needed none of your secrets. **Start at Part 2.** The commands are kept below for reference and re-runs.

| | State |
|---|---|
| `WSParticipantRole` | Exists (created 2026-07-06), now carrying **exactly** the 6 managed policies `contentspec.yaml` lists — `AWSCloudShellFullAccess` was missing and has been attached. Its trust policy admits `aws_oscar.medina_test-developer`, and assuming it was verified end-to-end. |
| Leftover inline policy | The July build's `WorkshopAthenaAudit` was **removed**, so the new build has to re-add it — its reappearance is now a real check rather than a pre-existing artifact. |
| Assets bucket | `cfn-sim-assets-865855451418-use1` (us-east-1, SSE-AES256, public access blocked), 233 objects synced under prefix `agentic-runtime-security-aws/`. Verified the branch's new code is in the uploaded tree. |
| Stale local state | Moved out of `infrastructure/` — see the note in "Before you start". |

Two things were confirmed empirically while doing this, and they are the reason the security controls exist: as `WSParticipantRole` you **can** call `secretsmanager:ListSecrets`, and you **can** list every bucket in the account. So neither the KMS deny nor the S3 bucket-policy deny is decorative — without them that role reaches the secrets and the full Tier-2 state.

Export these before Part 2:

```bash
export SIM_REGION=us-east-1
export SIM_STACK=cfn-sim-atevent
export ACCT=865855451418
export SIM_BUCKET="cfn-sim-assets-${ACCT}-use1"
export SIM_PREFIX="agentic-runtime-security-aws/"
```

**Re-run this after any code change**, or CodeBuild sources stale code:

```bash
bash workshop/scripts/package-assets.sh
aws s3 sync workshop/assets/ "s3://${SIM_BUCKET}/${SIM_PREFIX}" \
  --exclude 'cfn/*' --exclude 'terraform/infrastructure/.terraform/*'
```

<details>
<summary>Reference — what Part 1 did, and why each piece matters</summary>

Three things make this a real simulation rather than an approximation. Skipping any of them means you are not testing what an attendee will hit.

### 1a. Region — use `us-east-1`

`contentspec.yaml` pins `deployableRegions.required: [us-east-1]` with `maxAccessibleRegions: 1`. The old dev-sim recipe in `workshop/cfn-wrapper/README.md` used `us-west-2`; that diverges from what a real event does.

```bash
export SIM_REGION=us-east-1
export SIM_STACK=cfn-sim-atevent
export ACCT=$(aws sts get-caller-identity --query Account --output text)
```

### 1b. Create a `WSParticipantRole` — this is mandatory, not optional

**The build will fail without it.** `buildspec.yml` grants the attendee role a scoped Athena policy with `aws iam put-role-policy`, which — unlike the two `aws eks` grants above it — has no `|| true` and runs under `set -e`. No role, failed build.

It also has to carry **exactly** the six managed policies `contentspec.yaml` grants, or the security tests are meaningless: the whole point is proving that a role holding `SecretsManagerReadWrite` and `ReadOnlyAccess` still cannot read the secrets or the full Tier-2 state.

```bash
cat > /tmp/ws-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCT}:root"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role --role-name WSParticipantRole \
  --assume-role-policy-document file:///tmp/ws-trust.json \
  --description "Simulated Workshop Studio participant role (dev-sim only)"

for p in ReadOnlyAccess AWSCertificateManagerFullAccess AmazonBedrockFullAccess \
         SecretsManagerReadWrite AmazonEC2ContainerRegistryPowerUser AWSCloudShellFullAccess; do
  aws iam attach-role-policy --role-name WSParticipantRole \
    --policy-arn "arn:aws:iam::aws:policy/${p}"
done

aws iam list-attached-role-policies --role-name WSParticipantRole \
  --query 'AttachedPolicies[].PolicyName' --output table
```

Expected: all six listed.

### 1c. Upload the assets under a key prefix

Workshop Studio passes `AssetsKeyPrefix` (`{{.AssetsBucketPrefix}}`), so the assets sit under a prefix, not at the bucket root. Simulate that.

```bash
export SIM_BUCKET="cfn-sim-assets-${ACCT}-use1"
export SIM_PREFIX="agentic-runtime-security-aws/"

bash workshop/scripts/package-assets.sh

aws s3api create-bucket --bucket "$SIM_BUCKET" --region "$SIM_REGION"
aws s3api put-bucket-encryption --bucket "$SIM_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$SIM_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3 sync workshop/assets/ "s3://${SIM_BUCKET}/${SIM_PREFIX}" \
  --exclude 'cfn/*' --exclude 'terraform/infrastructure/.terraform/*'
```

`package-assets.sh` rsyncs `infrastructure/` into `workshop/assets/terraform/` and runs secret-leak gates — it is what pulls the branch's script changes into what CodeBuild will run. **Re-run it after every code change** or you will test stale code.

</details>

---

## Part 2 — Deploy (the happy path) — START HERE

Run this from the repo root, on branch `feat/21-tier2-preprovision-codebuild`. **Self-contained — no variables from earlier sections needed.**

Substitute only the two IBM values. The license is read from the file, already confirmed present at 1412 bytes:

```bash
cd /Users/oscar.medina/git-repos/agentic-runtime-security-aws

aws cloudformation deploy \
  --template-file workshop/static/cfn/bootstrap.yaml \
  --stack-name cfn-sim-atevent \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    TerraformSourceBucket="cfn-sim-assets-865855451418-use1" \
    AssetsKeyPrefix="agentic-runtime-security-aws/" \
    AcmeEmail="" \
    IcrEntitlementKey="PASTE_YOUR_ICR_KEY" \
    IviaMmfaPushClientSecret="PASTE_YOUR_MMFA_SECRET" \
    VaultEnterpriseLicense="$(cat ~/Downloads/vault-ent.hclic)"
```

> `~/Downloads/` also holds a `vault.hclic` (Jul 22) alongside `vault-ent.hclic` (Jul 23). The command uses `vault-ent.hclic`, which is the path `deploy-workshop.sh` defaults to — swap it if the other is the current Enterprise license.

Then set these for Parts 3–6, which do use variables:

```bash
export SIM_REGION=us-east-1
export SIM_STACK=cfn-sim-atevent
export ACCT=865855451418
export SIM_BUCKET="cfn-sim-assets-${ACCT}-use1"
export SIM_PREFIX="agentic-runtime-security-aws/"
```

Watch it (the stack stays `CREATE_IN_PROGRESS` until the build calls back):

```bash
aws logs tail /aws/codebuild/workshop-tier1 --follow --region us-east-1
```

If the log group does not exist yet, the build has not started — give it a moment and retry, or find the build with:

```bash
aws codebuild list-builds-for-project --region us-east-1 --project-name \
  "$(aws cloudformation describe-stacks --stack-name cfn-sim-atevent --region us-east-1 \
     --query "Stacks[].Outputs[?OutputKey=='CodeBuildProjectName'].OutputValue|[]|[0]" --output text)" \
  --query 'ids[0]' --output text
```

Expected in the log, in order: tier-1 steps 1–4 → `Tier-1 deploy complete` → tier-2 steps 5–9 → `Gate: Tier-2 exit contract (Vault issuer_id = https://wrp.….nip.io)` → state staged → `Vault license file removed from the build container.`

Expected end state: build `SUCCEEDED`, stack `CREATE_COMPLETE`. Budget ~35–45 min.

---

## Part 3 — Organizer-side checks

```bash
export STATE_BUCKET=$(aws cloudformation describe-stacks --stack-name "$SIM_STACK" --region "$SIM_REGION" \
  --query "Stacks[].Outputs[?OutputKey=='StateBucketName'].OutputValue|[]|[0]" --output text)

aws s3 ls "s3://${STATE_BUCKET}/" --recursive
```

Expected: `tier1/terraform.tfstate`, `tier1/terraform.tfvars`, `tier2/terraform.tfstate`, `tier2/.acme-state`, `tier2/vault-init.json`, `tier2-private/terraform.tfstate`.

**The attendee copy must carry no secrets:**

```bash
aws s3 cp "s3://${STATE_BUCKET}/tier2/terraform.tfstate" /tmp/t2-attendee.tfstate
jq -e '.resources == []' /tmp/t2-attendee.tfstate && echo "PASS: no resources"
jq -e '.outputs | length > 0' /tmp/t2-attendee.tfstate && echo "PASS: outputs present"
grep -Eic 'dockerconfigjson|imc_client_secret|"license"' /tmp/t2-attendee.tfstate
```

Expected: both `PASS` lines, and the grep prints `0`. **Anything other than `0` is release-blocking** — it means every attendee has the Vault Enterprise license.

**The secrets are present (they must be — teardown needs them):**

```bash
aws secretsmanager list-secrets --region "$SIM_REGION" \
  --query "SecretList[?contains(Name,'${SIM_STACK}')].Name" --output table
```

Expected: all three.

---

## Part 4 — Attendee-side checks (as `WSParticipantRole`)

This is the part that proves the security design. Assume the role:

```bash
# Keep your own identity so you can get back afterwards.
CREDS=$(aws sts assume-role --role-arn "arn:aws:iam::${ACCT}:role/WSParticipantRole" \
  --role-session-name attendee-sim \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)

aws sts get-caller-identity
```

Expected: an ARN containing `assumed-role/WSParticipantRole/attendee-sim`.

To drop back to your own identity at any point:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN && aws sts get-caller-identity
```

**Must FAIL — the license:**

```bash
aws secretsmanager get-secret-value --region "$SIM_REGION" \
  --secret-id "${SIM_STACK}-vault-enterprise-license"
```

Expected: `AccessDeniedException`, and specifically a **KMS** denial — the role can reach the secret, the key policy is what stops it. A returned value is release-blocking.

**Must FAIL — the full Tier-2 state:**

```bash
aws s3 cp "s3://${STATE_BUCKET}/tier2-private/terraform.tfstate" /tmp/should-fail.tfstate
```

Expected: `AccessDenied`. A successful download is release-blocking — that file has all three secrets in plaintext.

**Must SUCCEED — what the attendee legitimately needs:**

```bash
aws s3 cp "s3://${STATE_BUCKET}/tier1/terraform.tfstate" /tmp/ok1 && \
aws s3 cp "s3://${STATE_BUCKET}/tier2/terraform.tfstate" /tmp/ok2 && \
aws s3 cp "s3://${STATE_BUCKET}/tier2/.acme-state"       /tmp/ok3 && \
aws s3 cp "s3://${STATE_BUCKET}/tier2/vault-init.json"   /tmp/ok4 && echo "all four OK"
```

Expected: `all four OK`. `vault-init.json` is the attendee's own Vault root token — eleven workshop pages read it, so it is deliberately readable.

**Then walk page 31 verbatim as the attendee** — clone, bootstrap, pull state, verify Tier 2, run Tier 3. Return to your own identity first if you'd rather (`unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`), but running it as `WSParticipantRole` is the faithful test.

---

## Part 5 — The failure tests (the reason this issue exists)

Each needs a **fresh stack** — `IgnoreUpdate: true` means a stack update is a deliberate no-op and will not re-run the build. Delete between runs.

**5a. Wrong entitlement key — the cheap one, do this first.** Deploy exactly as Part 2 but with `IcrEntitlementKey="deliberately-wrong"`. IVIA cannot pull its images and Tier 2 fails well before the ACME gate.

Expected: build **FAILED**, stack **not** `CREATE_COMPLETE`. A passing build here would also mean the key never reached Terraform at all.

**5b. Broken ACME.** Fresh stack, valid secrets, but force Step 7's certificate gate to trip (point the ClusterIssuer at an unreachable ACME directory, or block the HTTP-01 solver path).

Expected: build **FAILED**, stack **not** `CREATE_COMPLETE`.

**5c. Timeout — the genuinely unknown one.** Deploy with `TimeoutInMinutes` edited down to something below a healthy run (say 20).

Expected: build `TIMED_OUT` **and** the stack reaches a failed state. If instead the stack sits in `CREATE_IN_PROGRESS`, then `finally` does not run on a timeout kill, CloudFormation is never told, and we need an EventBridge rule on CodeBuild state change to send the failure. **This one is untested and I could not determine the answer without running it.**

---

## Part 6 — Teardown

```bash
aws cloudformation delete-stack --stack-name "$SIM_STACK" --region "$SIM_REGION"
aws cloudformation wait stack-delete-complete --stack-name "$SIM_STACK" --region "$SIM_REGION"
```

The delete fires a teardown build that destroys Tier 2 first (while the cluster still exists, so the IVIA/Vault PVCs and their EBS volumes and the WRP ALB get reconciled), then sweeps Tier 1.

Then clean up the simulation scaffolding:

```bash
aws s3 rb "s3://${SIM_BUCKET}" --force
aws s3 rb "s3://${STATE_BUCKET}" --force   # retained by design; holds tier2-private/ with the secrets

aws iam delete-role-policy --role-name WSParticipantRole --policy-name WorkshopAthenaAudit 2>/dev/null || true
for p in ReadOnlyAccess AWSCertificateManagerFullAccess AmazonBedrockFullAccess \
         SecretsManagerReadWrite AmazonEC2ContainerRegistryPowerUser AWSCloudShellFullAccess; do
  aws iam detach-role-policy --role-name WSParticipantRole --policy-arn "arn:aws:iam::aws:policy/${p}"
done
aws iam delete-role --role-name WSParticipantRole
```

Delete the state bucket deliberately — it is retained on stack delete and `tier2-private/` holds the licensing secrets in plaintext.

---

## Re-running against a live environment

To re-run the build without disturbing the stack (no callback is sent — the buildspec takes its dev-sim branch when `CFN_EVENT_RESPONSE_URL` is absent):

```bash
aws codebuild start-build --region "$SIM_REGION" --project-name \
  "$(aws cloudformation describe-stacks --stack-name "$SIM_STACK" --region "$SIM_REGION" \
     --query "Stacks[].Outputs[?OutputKey=='CodeBuildProjectName'].OutputValue|[]|[0]" --output text)"
```

---

## What still differs from a real Workshop Studio event

- **Identity.** The simulated `WSParticipantRole` has an account-root trust policy; Workshop Studio's real one is federated. Permissions are identical, which is what the tests exercise.
- **Assets bucket.** Real events use the Workshop Studio assets bucket via `{{.AssetsBucketName}}`. Whether that resolves to a bucket in the event region is the open `@JONATHAN` question already noted in `contentspec.yaml` — it matters for a non-`us-east-1` event.
- **Parameter entry.** You pass the three secrets on the CLI here; at an event they are typed into the Workshop Studio event-creation form. The `VERIFY-ON-REAL-WS` note in Part 0 covers the risk.
