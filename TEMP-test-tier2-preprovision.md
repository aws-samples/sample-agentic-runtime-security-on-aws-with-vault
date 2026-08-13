# TEMP — Testing Tier-2 pre-provisioning (issue #21)

Scratch file for testing the `feat/21-tier2-preprovision-codebuild` branch. Delete when done.

---

## RUN THIS

```bash
cd /Users/oscar.medina/git-repos/agentic-runtime-security-aws && ./workshop/cfn-wrapper/sim-workshop-studio.sh --icr-key 'PASTE_ICR_KEY' --mmfa-secret 'PASTE_MMFA_SECRET'
```

## THEN TAIL THIS (second terminal)

```bash
aws logs tail /aws/codebuild/workshop-tier1 --follow --region us-east-1
```

## CHECK STATUS ANY TIME (third terminal, or after Ctrl-C)

```bash
cd /Users/oscar.medina/git-repos/agentic-runtime-security-aws && ./workshop/cfn-wrapper/sim-workshop-studio.sh --status
```

That is the whole test. The script does region, `WSParticipantRole`, `package-assets.sh`, the upload and the stack, pausing before each of its six steps. It also prints both tail commands and the console links itself, so you never need to come back here for them.

The Vault license defaults to `~/Downloads/vault-ent.hclic` (1412 bytes, confirmed). Add `--license PATH` to use a different one.

**The stack will sit at `CREATE_IN_PROGRESS` on `Tier1Deployment` for 35–45 minutes with no visible movement. That is correct.** CloudFormation is told nothing until the build's final callback, so judge progress by the CodeBuild log, never by stack events.

Expected in the log, in order: tier-1 steps 1–4 → `Tier-1 deploy complete` → tier-2 steps 5–9 → `Gate: Tier-2 exit contract (Vault issuer_id = https://wrp.….nip.io)` → state staged → `Vault license file removed from the build container.` Expected end state: build `SUCCEEDED`, stack `CREATE_COMPLETE`.

Everything below is reference — Parts 3 to 6 are the checks and failure injections to run *after* the deploy succeeds.

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

## Part 1 — Reference for the deploy command at the top

### What the script stops at

| Step | What it does | What to look at |
|---|---|---|
| 1 | Preflight | account, tooling, license size, and **that no `cfn-sim-atevent` stack exists** |
| 2 | `WSParticipantRole` | the six policies attach and are verified; a stale `WorkshopAthenaAudit` is removed so the build has to re-add it |
| 3 | Package + upload | every `package-assets.sh` leak gate passes; buildspec and `deploy-workshop.sh` confirmed in S3 |
| 4 | Create the stack | last stop before anything is provisioned |
| 5 | Follow | polls stack status every 60s; reprints both tail commands and the console links |
| 6 | Result | staged artifacts under `tier1/`, `tier2/`, `tier2-private/` |

The deploy runs in the background, so **Ctrl-C at any prompt leaves it running.**

To keep the secrets out of your shell history, export them and run the script bare:

```bash
read -rs ICR_ENTITLEMENT_KEY && export ICR_ENTITLEMENT_KEY
read -rs IVIA_MMFA_PUSH_CLIENT_SECRET && export IVIA_MMFA_PUSH_CLIENT_SECRET
./workshop/cfn-wrapper/sim-workshop-studio.sh
```

### The one trap worth knowing

**A stack UPDATE never re-runs the build.** `Tier1Deployment` carries `IgnoreUpdate: true`, so re-deploying over an existing stack updates the template and provisions nothing — it looks like success and stages nothing. This is exactly what happened on the Aug 4 stack. The script refuses to run when the stack already exists and tells you to delete it first; that refusal is the feature, not an obstacle.

### Two things already confirmed empirically

As `WSParticipantRole` you **can** call `secretsmanager:ListSecrets`, and you **can** list every bucket in the account. So neither the KMS deny nor the S3 bucket-policy deny is decorative — without them that role reaches the secrets and the full Tier-2 state.

---

## Part 2 — Variables for Parts 3–6

Parts 3 onward use these:

```bash
export SIM_REGION=us-east-1
export SIM_STACK=cfn-sim-atevent
export ACCT=865855451418
export SIM_BUCKET="cfn-sim-assets-${ACCT}-useast1"
export SIM_PREFIX="agentic-runtime-security-aws/"
```

`SIM_BUCKET` must match what the script computes — it derives the suffix as `$(echo us-east-1 | tr -d '-')`, so `useast1`, not the old hand-abbreviated `use1`. Part 6's teardown deletes this bucket, so a mismatch there would leave it behind.

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
