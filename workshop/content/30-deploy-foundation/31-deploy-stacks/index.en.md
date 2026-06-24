---
title: 'Deploy the Workshop'
weight: 31
---

Three Terraform roots, applied in dependency order. Each downstream root reads the upstream root's state, so Terraform enforces the ordering for you. Run `bootstrap.sh` once, then one tier at a time — natural checkpoints between EKS, Vault + IVIA, and the Use Case workloads.

- **Tier 1** — `infrastructure/` — VPC, EKS, add-ons, RDS, Bedrock KB, IAM
- **Tier 2** — `infrastructure/services/` — Vault server + IBM Verify Identity Access
- **Tier 3** — `infrastructure/workloads/` — Use Case 1, 2, 3 agent pods

## Default deploy — pre-built public images (GHCR)

By default `deploy-workshop.sh` pulls the five Use Case images as pre-built public packages from GHCR (`ghcr.io/sharepointoscar/*:v1`) anonymously at pod start. No container runtime, no image build, no ECR. The image source is configurable via `ghcr_registry_base` (default `ghcr.io/sharepointoscar`); see the [Bring Your Own GHCR Registry](../../90-resources/#bring-your-own-ghcr-registry) reference for the fork flow.

## Step 1 — Bootstrap (one-time)

Seeds the three `terraform.tfvars` files from their templates, stamps the tier-1 admin ARN from your account, and runs `terraform init` in all three roots. Idempotent.

```bash
bash infrastructure/scripts/bootstrap.sh
```

## Step 2 — Deploy Tier 1 (core infrastructure)

VPC, EKS cluster, managed add-ons (cert-manager, external-dns, AWS Load Balancer Controller), RDS PostgreSQL with pgaudit, Bedrock KB, IAM, and the audit substrate. **No application pods yet.**

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1
```

On your **first run** the script prompts for three values it cannot store in the repo — paste each when asked:

- **Let's Encrypt contact email** — a real, deliverable address for TLS certificate issuance/renewal notices (the `example.com` placeholder is rejected).
- **IBM Container Registry entitlement key** — from [Obtain IVIA Licenses](../../20-prerequisites/22-ivia-licensing/) (input hidden).
- **IBM Verify MMFA push client secret** — required by Use Case 3 (input hidden).

The script writes them into the gitignored `terraform.tfvars` files, so subsequent tiers and re-runs reuse them silently.

:::alert{header="Tier 1 timing" type="info"}
~22–30 min on first run — EKS ~12 min, RDS ~10 min (incl. pgaudit reboot), Bedrock KB ~3 min, add-ons ~5 min. Timing tracks AWS API response.
:::

## Step 3 — Deploy Tier 2 (Vault + IVIA)

Applies Vault HA + IVIA, initializes Vault (`~/vault-init.json`), issues the Let's Encrypt `nip.io` cert, imports it into ACM, re-applies IVIA on the trusted host, configures Vault auth/policies/secrets engines, and verifies the IVIA OIDC discovery endpoint.

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 2
```

:::alert{header="Tier 2 timing" type="info"}
~10–15 min — Vault Raft converge ~3 min, IVIA pods ~5 min, ACME issuance + ACM import + IVIA re-apply ~3 min, Vault + IVIA configure ~2 min.
:::

## Step 4 — Deploy Tier 3 (Use Case workloads)

Applies the Use Case 1, 2, 3 agent pods. In the default GHCR mode pods start pulling images anonymously — no deployment roll required. The step also runs the shared-ALB assertion + IVIA redirect reconcile, verifies the OpenLDAP `oscar` user, seeds the banking database, and ingests the Bedrock KB corpus.

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 3
```

:::alert{header="Tier 3 timing" type="info"}
~5–10 min — workloads apply ~3 min, DB seed + KB ingest ~3 min.
:::

## Re-runs and recovery

Every step is idempotent — re-running a tier converges what's missing and skips what's already done. If a step fails the script hard-stops on it and prints a `Fix:` hint; fix the cause and re-run the same `--tier N` command.

When the cluster and Vault init are already done, the slow stages can be skipped on a tier-1 re-run:

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1 --skip-infra --skip-vault-init
```

Tier-1 outputs referenced by later pages: `kubectl_config_command`, `kb_id`, `rds_endpoint`.

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
