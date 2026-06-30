---
title: 'Deploy — Self-paced'
weight: 31
---

Run the full stack from scratch on your own AWS account. Three Terraform roots, applied in dependency order — each downstream root reads the upstream root's state, so Terraform enforces the ordering for you.

- **Tier 1** — `infrastructure/` — VPC, EKS, add-ons, RDS, Bedrock KB, IAM
- **Tier 2** — `infrastructure/services/` — Vault server + IBM Verify Identity Access
- **Tier 3** — `infrastructure/workloads/` — Use Case 1, 2, and 3 agent pods

::::alert{header="At a hosted event instead?" type="info"}
If you joined via a Workshop Studio invite link, Tier 1 is already running — follow **[Deploy — At an Event](../31-deploy-at-an-event/)** and skip straight to Tier 2.
::::

By default `deploy-workshop.sh` pulls the five Use Case images as pre-built public packages from GHCR (`ghcr.io/sharepointoscar/*:v1`) anonymously at pod start — no container runtime, no image build, no ECR. To build them yourself instead, see [Build images locally](#build-images-locally---image-source-ecr) below.

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

When all three tiers report success, continue with **[Configure kubectl](../32-configure-kubectl/)** — from here the remaining pages are identical for every attendee.

---

## Re-runs and recovery

Every step is idempotent — re-running a tier converges what's missing and skips what's already done. If a step fails the script hard-stops on it and prints a `Fix:` hint; fix the cause and re-run the same `--tier N` command.

When the cluster and Vault init are already done, the slow stages can be skipped on a Tier-1 re-run:

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

---

## Build images locally (`--image-source ecr`)

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
