---
title: 'Deploy — At an Event'
weight: 31
---

Tier 1 (the EKS foundation) was already provisioned by CloudFormation + CodeBuild when your event account was set up. **You skip the `--tier 1` apply** and go straight to your hands-on work — Tier 2 (Vault + IBM Verify Identity Access) and Tier 3 (the Use Case 1, 2, and 3 agent pods).

::::alert{header="On your own AWS account instead?" type="info"}
Follow **[Deploy — Self-paced](../31-deploy-self-paced/)** — you bootstrap and apply all three tiers yourself.
::::

By default the deploy pulls the five Use Case images as pre-built public packages from GHCR (`ghcr.io/sharepointoscar/*:v1`) anonymously at pod start — no container runtime, no image build, no ECR.

#### Step 1 — Clone the repository

Clone the workshop repo at the pinned event tag from the public mirror:

```bash
git clone https://github.com/sharepointoscar/agentic-runtime-security-aws.git && cd agentic-runtime-security-aws
```

#### Step 2 — Bootstrap (prep only — no infrastructure deploy)

`bootstrap.sh` seeds the three `terraform.tfvars` files from their templates and runs `terraform init` in all three roots. It does **not** deploy infrastructure — it just prepares the repo so `deploy-workshop.sh` can read your IVIA secrets and run `terraform apply` for Tier 2 and Tier 3.

```bash
bash infrastructure/scripts/bootstrap.sh --skip-prereq-gate
```

On your **first run** the script prompts for three values — paste each when asked:

- **Let's Encrypt contact email** — the email you registered with for this event (or any real, deliverable address).
- **IBM Container Registry entitlement key** — from [Obtain IVIA Licenses](../../20-prerequisites/22-ivia-licensing/) (input hidden).
- **IBM Verify MMFA push client secret** — required by Use Case 3 (input hidden).

#### Step 3 — Pull the Tier-1 state

The CodeBuild build staged the Tier-1 Terraform state to an S3 bucket. Discover the bucket name from the CloudFormation stack output and pull the state to the exact path Tier 2 and Tier 3 read:

```bash
STATE_BUCKET=$(aws cloudformation describe-stacks --query "Stacks[].Outputs[?OutputKey=='StateBucketName'].OutputValue|[]|[0]" --output text) && aws s3 cp "s3://${STATE_BUCKET}/infrastructure/terraform.tfstate" infrastructure/terraform.tfstate && test -s infrastructure/terraform.tfstate && echo "State pulled OK" || echo "ERROR: state file missing or empty"
```

::::alert{header="State file path is load-bearing" type="warning"}
The state file must be at exactly `infrastructure/terraform.tfstate` relative to the repo root. The Tier-2 and Tier-3 roots read it via a relative `../terraform.tfstate` path — any other location fails `terraform apply` with a missing-outputs error.
::::

::::alert{header="If the CloudFormation query returns empty" type="info"}
If `STATE_BUCKET` resolves to empty (for example, if the stack outputs aren't visible yet), list buckets and locate the state bucket by name, then rerun the `aws s3 cp` with that name:

```bash
aws s3 ls | grep -i workshop
```
::::

#### Step 4 — Deploy Tier 2 (Vault + IVIA)

The IVIA credentials you entered during bootstrap are in the gitignored `terraform.tfvars` files — the script uses them silently.

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

**3. Validate the fix** — Vault's `jwt` `bound_issuer` must be the `nip.io` host, not an `*.elb.amazonaws.com` load-balancer hostname:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json) && kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read auth/jwt/config" | grep bound_issuer
```

Expected — the `nip.io` FQDN (resolve the exact value with `grep NIP_FQDN_WRP infrastructure/.acme-state`):

```
bound_issuer    https://wrp.<deploy-id>.<alb-ip-dashed>.nip.io
```

If it still shows an `*.elb.amazonaws.com` host, the IVIA re-apply did not run — confirm the certificate is `Ready=True`, that you did **not** pass `--skip-acme`, then re-run the Tier 2 command above.
