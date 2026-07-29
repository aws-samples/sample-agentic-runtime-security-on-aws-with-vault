---
title: 'Deploy — At an Event'
weight: 31
---

The EKS cluster was already provisioned as part of your AWS account setup. You'll now deploy Vault + IBM Verify Identity Access, then the agent applications.

::::alert{header="On your own AWS account instead?" type="info"}
Follow **[Deploy — Self-paced](../31-deploy-self-paced/)** — you bootstrap and apply all three tiers yourself.
::::

#### Step 1 — Clone the repository

Clone the workshop repo at the pinned event tag from the public mirror:

```bash
git clone https://github.com/sharepointoscar/agentic-runtime-security-aws.git && cd agentic-runtime-security-aws
```

#### Step 2 — Bootstrap

`bootstrap.sh` seeds the `terraform.tfvars` files from their templates and runs `terraform init` in all three roots. It does **not** deploy infrastructure and does **not** prompt for anything (you'll supply your IBM secrets at Step 4). It just prepares the repo so you can apply Tier 2 and Tier 3.

`--image-source ecr` points the workload images at **your own account's ECR** — the CodeBuild that provisioned Tier 1 already built and pushed the Use Case images there, so bootstrap stamps the `<account>.dkr.ecr.<region>...` URIs (your account + region, resolved automatically) into the Tier-3 config. No public image pulls at runtime.

```bash
bash infrastructure/scripts/bootstrap.sh --skip-prereq-gate --image-source ecr
```

#### Step 3 — Pull the Tier-1 state and config

The CodeBuild build staged the Tier-1 Terraform **state** and its **`terraform.tfvars`** (which already carries the event's Let's Encrypt email) to an S3 bucket. Discover the bucket name from the CloudFormation stack output and pull both to the paths Tier 2 and Tier 3 read:

```bash
STATE_BUCKET=$(aws cloudformation describe-stacks --query "Stacks[].Outputs[?OutputKey=='StateBucketName'].OutputValue|[]|[0]" --output text) && aws s3 cp "s3://${STATE_BUCKET}/tier1/terraform.tfstate" infrastructure/terraform.tfstate && aws s3 cp "s3://${STATE_BUCKET}/tier1/terraform.tfvars" infrastructure/terraform.tfvars && test -s infrastructure/terraform.tfstate && echo "State + config pulled OK" || echo "ERROR: pull failed"
```

::::alert{header="State file path is load-bearing" type="warning"}
The state file must be at exactly `infrastructure/terraform.tfstate` relative to the repo root. The Tier-2 and Tier-3 roots read it via a relative `../terraform.tfstate` path — any other location fails `terraform apply` with a missing-outputs error.
::::

::::alert{header="If the CloudFormation query returns empty" type="info"}
If `STATE_BUCKET` resolves to empty (for example, if the stack outputs aren't visible yet), list buckets and locate the state bucket by name, then rerun both `aws s3 cp` commands with that bucket name:

```bash
aws s3 ls | grep -i bootstrap-statebucket
```
::::

#### Step 4 — Deploy Tier 2 (Vault + IVIA)

The **first** time you run `deploy-workshop.sh`, a preflight check prompts for the two IBM secrets it needs — paste each when asked (input is hidden):

- **IBM Container Registry entitlement key** — from [Obtain IVIA Licenses](../../20-prerequisites/22-ivia-licensing/).
- **IBM Verify MMFA push client secret** — required by Use Case 3.

Your event organizer provides these two values. Paste them at the prompts, **or** export them before running for a hands-off deploy — the preflight uses the environment variables when set and skips the prompts:

```bash
export ICR_ENTITLEMENT_KEY="<value from your organizer>"
export IVIA_MMFA_PUSH_CLIENT_SECRET="<value from your organizer>"
```

Either way, the values are written only into the gitignored `terraform.tfvars` — never committed.

Tier 2 also needs a **Vault Enterprise license** — Vault runs in Enterprise mode for the native Agent Registry. Unlike the two secrets above it is read from a **file**, not a prompt, so place it before you run the deploy: save the `.hclic` your organizer provides to `~/Downloads/vault-ent.hclic`, or point `VAULT_ENTERPRISE_LICENSE_PATH` at it. The preflight fails fast (and tells you the path) if the file is missing.

```bash
# organizer-provided Vault Enterprise license — save to the default path...
cp /path/to/vault-ent.hclic ~/Downloads/vault-ent.hclic
# ...or point the env var at wherever you saved it:
export VAULT_ENTERPRISE_LICENSE_PATH=/path/to/vault-ent.hclic
```

It does **not** ask for a Let's Encrypt email — that was set when CodeBuild provisioned Tier 1, and you pulled it in Step 3.

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 2
```

::::alert{header="Tier 2 timing" type="info"}
~10–15 min — Vault Raft converge ~3 min, IVIA pods ~5 min, ACME issuance + ACM import + IVIA re-apply ~3 min, Vault + IVIA configure ~2 min.
::::

#### Step 5 — Deploy Tier 3 (Use Case workloads)

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 3
```

::::alert{header="Tier 3 timing" type="info"}
~5–10 min — workloads apply ~3 min, DB seed + KB ingest ~3 min.
::::

When both tiers report success, continue with **[Configure kubectl](../32-configure-kubectl/)** — from here the remaining pages are identical for every attendee.

---

## If Tier 2 fails on the Let's Encrypt cert (`Step 7: Certificate Ready=true`)

On the Tier 2 deploy you may see this in the Step 7 summary:

```
✗ Step 7: Certificate Ready=true
   Fix: cert-manager did not mark workshop-le-tls Ready within 900s
```

**What happened:** Let's Encrypt issuance for the fresh `nip.io` host occasionally takes longer than Step 7's 15-minute readiness gate. When the gate trips, the deploy records the failure and continues — but the "re-apply IVIA on the trusted host" sub-step is skipped, so Vault's `jwt` auth stays bound to the internal load-balancer hostname instead of the public `nip.io` issuer. Use Case 2 and Use Case 3 token validation depend on that issuer, so correct this before Tier 3.

**1. Confirm the certificate finished issuing** (wait a minute or two after the gate trips), until `READY` shows `True`:

```bash
kubectl get certificate workshop-le-tls -n cert-manager
```

**2. Re-run Tier 2 with `--skip-vault-init`** (Vault is already initialized). With the cert now Ready, Step 7 passes immediately and runs the IVIA re-apply that fixes the issuer:

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 2 --skip-vault-init
```

::::alert{header="Do not add --skip-acme" type="warning"}
`--skip-acme` returns before the IVIA re-apply step, so it will **not** correct the issuer. Re-run with `--skip-vault-init` only.
::::

**3. Validate the fix** — Vault's OAuth resource server `issuer_id` must be the `nip.io` host, not an `*.elb.amazonaws.com` load-balancer hostname:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json) && kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read sys/config/oauth-resource-server/ivia" | grep issuer_id
```

Expected — the `nip.io` FQDN (resolve the exact value with `grep NIP_FQDN_WRP infrastructure/.acme-state`):

```
issuer_id    https://wrp.<deploy-id>.<alb-ip-dashed>.nip.io
```

If it still shows an `*.elb.amazonaws.com` host, the IVIA re-apply did not run — confirm the certificate is `Ready=True`, that you did **not** pass `--skip-acme`, then re-run the Tier 2 command above.
