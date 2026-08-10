---
title: 'Deploy — At an Event'
weight: 31
---

The EKS cluster **and** Vault + IBM Verify Identity Access were already provisioned as part of your AWS account setup. You'll verify that foundation, then deploy the agent applications yourself.

::::alert{header="On your own AWS account instead?" type="info"}
Follow **[Deploy — Self-paced](../31-deploy-self-paced/)** — you bootstrap and apply all three tiers yourself.
::::

#### Step 1 — Clone the repository

Clone the workshop repo at the pinned event tag from the public mirror:

```bash
git clone https://github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault.git && cd sample-agentic-runtime-security-on-aws-with-vault
```

#### Step 2 — Bootstrap

`bootstrap.sh` seeds the `terraform.tfvars` files from their templates and runs `terraform init` in all three roots. It does **not** deploy infrastructure and does **not** prompt for anything. It just prepares the repo so you can apply Tier 3.

`--image-source ecr` points the workload images at **your own account's ECR** — the CodeBuild that provisioned Tier 1 already built and pushed the Use Case images there, so bootstrap stamps the `<account>.dkr.ecr.<region>...` URIs (your account + region, resolved automatically) into the Tier-3 config. No public image pulls at runtime.

```bash
bash infrastructure/scripts/bootstrap.sh --skip-prereq-gate --image-source ecr
```

#### Step 3 — Pull the pre-provisioned state

The CodeBuild build staged what it deployed to an S3 bucket: the Tier-1 state and its `terraform.tfvars` (which already carries the event's Let's Encrypt email), the Tier-2 state, the `.acme-state` file holding your event's `nip.io` hostnames, and your Vault root token. Discover the bucket from the CloudFormation stack output and pull all five to the paths Tier 3 reads:

```bash
STATE_BUCKET=$(aws cloudformation describe-stacks --query "Stacks[].Outputs[?OutputKey=='StateBucketName'].OutputValue|[]|[0]" --output text) && aws s3 cp "s3://${STATE_BUCKET}/tier1/terraform.tfstate" infrastructure/terraform.tfstate && aws s3 cp "s3://${STATE_BUCKET}/tier1/terraform.tfvars" infrastructure/terraform.tfvars && aws s3 cp "s3://${STATE_BUCKET}/tier2/terraform.tfstate" infrastructure/services/terraform.tfstate && aws s3 cp "s3://${STATE_BUCKET}/tier2/.acme-state" infrastructure/.acme-state && aws s3 cp "s3://${STATE_BUCKET}/tier2/vault-init.json" ~/vault-init.json && test -s infrastructure/services/terraform.tfstate && echo "State + config pulled OK" || echo "ERROR: pull failed"
```

::::alert{header="State file paths are load-bearing" type="warning"}
The files must land at exactly `infrastructure/terraform.tfstate` and `infrastructure/services/terraform.tfstate` relative to the repo root. Tier 3 reads them via relative `../terraform.tfstate` and `../services/terraform.tfstate` paths — any other location fails `terraform apply` with a missing-outputs error. `~/vault-init.json` is where every later page expects to find your Vault root token.
::::

::::alert{header="Why the Tier-2 state looks empty" type="info"}
Open `infrastructure/services/terraform.tfstate` and you'll see `"resources": []`. That is deliberate, not a broken download. Terraform records every resource's attributes in state — including the Vault Enterprise license and the IBM entitlement key your organizer supplied — so you receive an outputs-only copy with the resource list stripped. Tier 3 reads only the outputs, so it works exactly the same.
::::

::::alert{header="If the CloudFormation query returns empty" type="info"}
If `STATE_BUCKET` resolves to empty (for example, if the stack outputs aren't visible yet), list buckets and locate the state bucket by name, then rerun both `aws s3 cp` commands with that bucket name:

```bash
aws s3 ls | grep -i bootstrap-statebucket
```
::::

#### Step 4 — Verify Tier 2 (Vault + IVIA)

Tier 2 is already running. The same CodeBuild that provisioned Tier 1 also deployed Vault and IBM Verify Identity Access, using the Vault Enterprise license and the two IBM secrets your organizer supplied **once** at event setup — which is why you were never asked for them.

That build fails outright if any part of Tier 2 is wrong, so an account that exists is an account whose foundation is sound. Confirm it for yourself and get a look at what was built.

First point `kubectl` at the cluster (the next page repeats this — it is idempotent):

```bash
$(terraform -chdir=infrastructure output -raw kubectl_config_command)
```

**Vault is initialized and unsealed:**

```bash
kubectl exec -n vault vault-0 -- vault status | grep -E "Initialized|Sealed|Version"
```

Expected — `Initialized true`, `Sealed false`, and an `+ent` build (Enterprise, required for the native Agent Registry):

```
Initialized     true
Sealed          false
Version         1.20.x+ent
```

**All seven IVIA pods are running:**

```bash
kubectl get pods -n verify-access
```

Expected — seven pods `Running` and fully `Ready` (`iviaconfig`, `iviadsc`, `iviaop`, `iviaruntime`, `iviawrprp1`, `openldap`, `postgresql`).

**The Let's Encrypt certificate issued:**

```bash
kubectl get certificate workshop-le-tls -n cert-manager
```

Expected — `READY` shows `True`. This is the step that most often needs patience on a self-paced deploy; at an event it completed during account setup.

**The contract that matters — Vault's OAuth issuer is your public `nip.io` host**, not an internal load-balancer name. Use Case 2 and Use Case 3 token validation both depend on it:

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json) && kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read sys/config/oauth-resource-server/ivia" | grep issuer_id
```

Expected — a `nip.io` FQDN matching `grep NIP_FQDN_WRP infrastructure/.acme-state`:

```
issuer_id    https://wrp.<deploy-id>.<alb-ip-dashed>.nip.io
```

::::alert{header="Looks broken, isn't" type="info"}
If you go looking at IVIA's own OIDC discovery document now, its `issuer` reads `https://issuer-patched-at-root.invalid`. That is **correct** at this point. Tier 2 deliberately ships placeholder hosts, and Tier 3 rewrites them once the banking-UI load balancer exists in the next step. The value you just checked in Vault is the one that had to be right.
::::

#### Step 5 — Deploy Tier 3 (Use Case workloads)

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 3
```

::::alert{header="Tier 3 timing" type="info"}
~5–10 min — workloads apply ~3 min, DB seed + KB ingest ~3 min.
::::

When Tier 3 reports success, continue with **[Configure kubectl](../32-configure-kubectl/)** — from here the remaining pages are identical for every attendee.

---

## If a Tier-2 check in Step 4 does not match

Raise it with your event organizer rather than trying to redeploy Tier 2 yourself — you do not hold the IBM secrets or the Vault Enterprise license it needs, and by design you never will.

This should not happen. The account-setup build hard-fails on any Tier-2 fault, including a `nip.io` certificate that never went `Ready` and an `issuer_id` still pointing at an internal `*.elb.amazonaws.com` host, so a broken Tier 2 fails the CloudFormation stack instead of producing an account. If you are looking at a healthy-looking account with a failing check, that is worth telling the organizer about.

Two things that look like failures and are not:

- **IVIA's OIDC discovery `issuer` reads `https://issuer-patched-at-root.invalid`** — correct until Tier 3 runs, as noted in Step 4.
- **`infrastructure/services/terraform.tfstate` has `"resources": []`** — correct; you are given an outputs-only copy so the licensing secrets stay out of your hands.
