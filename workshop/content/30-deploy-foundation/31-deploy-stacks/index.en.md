---
title: 'Deploy the Workshop'
weight: 31
---

Three Terraform roots, applied in dependency order. Each downstream root reads the upstream root's state, so Terraform enforces the ordering for you.

- **Tier 1** — `infrastructure/` — VPC, EKS, add-ons, RDS, Bedrock KB, IAM
- **Tier 2** — `infrastructure/services/` — Vault server + IBM Verify Identity Access
- **Tier 3** — `infrastructure/workloads/` — Use Case 1, 2, and 3 agent pods

**Know your path before continuing:** If you joined via a Workshop Studio invite link, follow [At an Event](#at-an-event) — Tier 1 is already running and you skip straight to Tier 2. If you are running the workshop on your own AWS account, follow [Self-paced](#self-paced).

## Default deploy — pre-built public images (GHCR)

By default `deploy-workshop.sh` pulls the five Use Case images as pre-built public packages from GHCR (`ghcr.io/sharepointoscar/*:v1`) anonymously at pod start. No container runtime, no image build, no ECR. The image source is configurable via `ghcr_registry_base` (default `ghcr.io/sharepointoscar`); see the [Bring Your Own GHCR Registry](../../90-resources/#bring-your-own-ghcr-registry) reference for the fork flow.

---

### At an Event

Tier 1 (EKS foundation) was provisioned by CloudFormation + CodeBuild when your account was set up. You skip `bootstrap.sh` and `--tier 1`. Your hands-on work is Tier 2 (Vault + IBM Verify Identity Access) and Tier 3 (Use Case 1, 2, and 3 agent pods).

#### Step 1 — Clone the repository

Clone the workshop repo at the pinned event tag from the public mirror:

```bash
git clone https://github.com/sharepointoscar/agentic-runtime-security-aws.git && cd agentic-runtime-security-aws
```

#### Step 2 — Pull the Tier-1 state

The CodeBuild build staged the Tier-1 Terraform state to an S3 bucket. Discover the bucket name from the CloudFormation stack output and pull the state to the exact path Tier 2 and Tier 3 read:

```bash
STATE_BUCKET=$(aws cloudformation describe-stacks --query "Stacks[].Outputs[?OutputKey=='StateBucketName'].OutputValue|[]|[0]" --output text) && mkdir -p infrastructure && aws s3 cp "s3://${STATE_BUCKET}/infrastructure/terraform.tfstate" infrastructure/terraform.tfstate
```

Confirm the file landed at the right path:

```bash
test -s infrastructure/terraform.tfstate && echo "State pulled OK" || echo "ERROR: state file missing or empty"
```

::::alert{header="State file path is load-bearing" type="warning"}
The state file must be at exactly `infrastructure/terraform.tfstate` relative to the repo root. The Tier-2 and Tier-3 roots read it via a relative `../terraform.tfstate` path. Any other location will cause `terraform apply` to fail with a missing outputs error.
::::

::::alert{header="If the CloudFormation query returns empty" type="info"}
If `STATE_BUCKET` resolves to empty (for example, if the stack outputs are not yet visible in the portal), you can list buckets in the account and locate the state bucket by name:

```bash
aws s3 ls | grep -i workshop
```

Copy the bucket name from the output and rerun: `aws s3 cp "s3://<bucket-name>/infrastructure/terraform.tfstate" infrastructure/terraform.tfstate`
::::

#### Step 3 — Configure kubectl and validate the cluster

Your `WSParticipantRole` session was granted EKS cluster access by the CodeBuild build. Update your kubeconfig and verify the nodes are ready:

```bash
CLUSTER=$(aws eks list-clusters --region us-west-2 --query "clusters[0]" --output text) && aws eks update-kubeconfig --name "$CLUSTER" --region us-west-2 && kubectl get nodes
```

**Expected output** — five nodes in `Ready` state:

```
NAME                                       STATUS   ROLES    AGE   VERSION
ip-10-1-1-xxx.us-west-2.compute.internal  Ready    <none>   20m   v1.34.x-eks-xxxx
ip-10-1-2-xxx.us-west-2.compute.internal  Ready    <none>   20m   v1.34.x-eks-xxxx
ip-10-1-3-xxx.us-west-2.compute.internal  Ready    <none>   20m   v1.34.x-eks-xxxx
ip-10-1-4-xxx.us-west-2.compute.internal  Ready    <none>   20m   v1.34.x-eks-xxxx
ip-10-1-5-xxx.us-west-2.compute.internal  Ready    <none>   20m   v1.34.x-eks-xxxx
```

If no nodes appear, confirm that `WSParticipantRole` is the identity your session is using (`aws sts get-caller-identity`) and that the CodeBuild build completed successfully (check the **CodeBuildConsoleLink** in the CloudFormation stack outputs).

#### Step 4 — Deploy Tier 2 (Vault + IVIA)

On your **first run** the script prompts for two values it cannot pre-provision: your IBM Container Registry entitlement key and your IBM Verify MMFA push client secret. Have them ready from [Obtain IVIA Licenses](../../20-prerequisites/22-ivia-licensing/). The Let's Encrypt email was provided by the event organizer — you do not need to supply it again.

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

The shared pages 32–38 (configure-kubectl, verify infrastructure, ingest knowledge base, verify Vault, verify IVIA, OIDC seam, platform health check) are identical for both paths — continue with [Configure kubectl](../32-configure-kubectl/).

---

### Self-paced

Run the full stack from scratch on your own AWS account. Bootstrap once, then apply each tier in order.

#### Step 1 — Bootstrap (one-time)

Seeds the three `terraform.tfvars` files from their templates, stamps the Tier-1 admin ARN from your account, and runs `terraform init` in all three roots. Idempotent.

```bash
bash infrastructure/scripts/bootstrap.sh
```

#### Step 2 — Deploy Tier 1 (core infrastructure)

VPC, EKS cluster, managed add-ons (cert-manager, external-dns, AWS Load Balancer Controller), RDS PostgreSQL with pgaudit, Bedrock KB, IAM, and the audit substrate. **No application pods yet.**

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1
```

On your **first run** the script prompts for three values it cannot store in the repo — paste each when asked:

- **Let's Encrypt contact email** — a real, deliverable address for TLS certificate issuance/renewal notices (the `example.com` placeholder is rejected).
- **IBM Container Registry entitlement key** — from [Obtain IVIA Licenses](../../20-prerequisites/22-ivia-licensing/) (input hidden).
- **IBM Verify MMFA push client secret** — required by Use Case 3 (input hidden).

The script writes them into the gitignored `terraform.tfvars` files, so subsequent tiers and re-runs reuse them silently.

::::alert{header="Tier 1 timing" type="info"}
~22–30 min on first run — EKS ~12 min, RDS ~10 min (incl. pgaudit reboot), Bedrock KB ~3 min, add-ons ~5 min. Timing tracks AWS API response.
::::

#### Step 3 — Deploy Tier 2 (Vault + IVIA)

Applies Vault HA + IVIA, initializes Vault (`~/vault-init.json`), issues the Let's Encrypt `nip.io` cert, imports it into ACM, re-applies IVIA on the trusted host, configures Vault auth/policies/secrets engines, and verifies the IVIA OIDC discovery endpoint.

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 2
```

::::alert{header="Tier 2 timing" type="info"}
~10–15 min — Vault Raft converge ~3 min, IVIA pods ~5 min, ACME issuance + ACM import + IVIA re-apply ~3 min, Vault + IVIA configure ~2 min.
::::

#### Step 4 — Deploy Tier 3 (Use Case workloads)

Applies the Use Case 1, 2, and 3 agent pods. In the default GHCR mode pods start pulling images anonymously — no deployment roll required. The step also runs the shared-ALB assertion + IVIA redirect reconcile, verifies the OpenLDAP `oscar` user, seeds the banking database, and ingests the Bedrock KB corpus.

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 3
```

::::alert{header="Tier 3 timing" type="info"}
~5–10 min — workloads apply ~3 min, DB seed + KB ingest ~3 min.
::::

---

## Re-runs and recovery

Every step is idempotent — re-running a tier converges what's missing and skips what's already done. If a step fails the script hard-stops on it and prints a `Fix:` hint; fix the cause and re-run the same `--tier N` command.

When the cluster and Vault init are already done, the slow stages can be skipped on a tier-1 re-run:

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1 --skip-infra --skip-vault-init
```

Tier-1 outputs referenced by later pages: `kubectl_config_command`, `kb_id`, `rds_endpoint`.

### Tier 2: Let's Encrypt cert timing (`Step 7: Certificate Ready=true` failed)

On the Tier 2 deploy you may see this in the Step 7 summary:

```
✗ Step 7: Certificate Ready=true
   Fix: cert-manager did not mark workshop-le-tls Ready within 900s
```

**What happened:** Let's Encrypt issuance for the fresh `nip.io` host occasionally takes longer than Step 7's 15-minute readiness gate. When the gate trips, the deploy records the failure and continues — but Step 7's "re-apply IVIA on the trusted host" sub-step is skipped, so Vault's `jwt` auth stays bound to the internal load-balancer hostname instead of the public `nip.io` issuer. Use Case 2 and Use Case 3 token validation depend on that issuer, so correct this before Tier 3.

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

---

## Self-paced opt-in: build images locally (`--image-source ecr`)

If you prefer to build the Use Case images locally and push them to your own ECR rather than pulling from GHCR, pass `--image-source ecr` to every `deploy-workshop.sh` invocation. This requires a running container runtime (Docker or Podman) — see the [Self-paced: build images locally](../../20-prerequisites/23-pre-flight-checks/#self-paced-build-images-locally---image-source-ecr) section in pre-flight checks.

In `ecr` mode: bootstrap stamps your `<account>/<region>` ECR image URIs into the tier-3 tfvars, Terraform provisions the ECR repos, the deploy builds the five images and pushes them to your ECR, and the deployments roll to pull the newly pushed `:latest` images.

```bash
bash infrastructure/scripts/deploy-workshop.sh --image-source ecr --tier 1
bash infrastructure/scripts/deploy-workshop.sh --image-source ecr --tier 2
bash infrastructure/scripts/deploy-workshop.sh --image-source ecr --tier 3
```

When the cluster and images are already done, use `--skip-infra --skip-build --skip-vault-init` to skip the slow stages:

```bash
bash infrastructure/scripts/deploy-workshop.sh --image-source ecr --tier 1 --skip-infra --skip-build --skip-vault-init
```

The `ghcr_registry_base` variable (default `ghcr.io/sharepointoscar`) is configurable via `--ghcr-registry-base` if you want to repoint the GHCR consume side to your own namespace. See [Bring Your Own GHCR Registry](../../90-resources/#bring-your-own-ghcr-registry) for the full fork flow.
