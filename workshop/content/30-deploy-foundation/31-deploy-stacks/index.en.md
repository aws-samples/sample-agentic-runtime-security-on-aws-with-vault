---
title: 'Deploy the Workshop'
weight: 31
---

Three Terraform roots, applied in dependency order. Each downstream root reads the upstream root's state, so Terraform enforces the ordering for you. Run `bootstrap.sh` once, then one tier at a time — natural checkpoints between EKS, Vault + IVIA, and the Use Case workloads.

- **Tier 1** — `infrastructure/` — VPC, EKS, add-ons, RDS, Bedrock KB, ECR, IAM
- **Tier 2** — `infrastructure/services/` — Vault server + IBM Verify Identity Access
- **Tier 3** — `infrastructure/workloads/` — Use Case 1, 2, 3 agent pods

## Step 1 — Bootstrap (one-time)

Seeds the three `terraform.tfvars` files from their templates, stamps the tier-3 ECR image URIs + tier-1 admin ARN from your account/region, and runs `terraform init` in all three roots. Idempotent.

```bash
bash infrastructure/scripts/bootstrap.sh
```

## Step 2 — Deploy Tier 1 (core infrastructure)

VPC, EKS cluster, managed add-ons (cert-manager, external-dns, AWS Load Balancer Controller), RDS PostgreSQL with pgaudit, Bedrock KB, ECR repos, IAM, and the audit substrate. The Use Case 1/2/3 images are built and pushed to ECR at the end of this tier. **No application pods yet.**

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1
```

On your **first run** the script prompts for three values it cannot store in the repo — paste each when asked:

- **Let's Encrypt contact email** — a real, deliverable address for TLS certificate issuance/renewal notices (the `example.com` placeholder is rejected).
- **IBM Container Registry entitlement key** — from [Obtain IVIA Licenses](../../20-prerequisites/22-ivia-licensing/) (input hidden).
- **IBM Verify MMFA push client secret** — required by Use Case 3 (input hidden).

The script writes them into the gitignored `terraform.tfvars` files, so subsequent tiers and re-runs reuse them silently.

:::alert{header="Tier 1 timing" type="info"}
~22–30 min on first run — EKS ~12 min, RDS ~10 min (incl. pgaudit reboot), Bedrock KB ~3 min, add-ons + image build ~5 min. Timing tracks AWS API response.
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

Applies the Use Case 1, 2, 3 agent pods, rolls the deployments to pick up the freshly pushed images, runs the shared-ALB assertion + IVIA redirect reconcile, verifies the OpenLDAP `oscar` user, seeds the banking database, and ingests the Bedrock KB corpus.

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 3
```

:::alert{header="Tier 3 timing" type="info"}
~5–10 min — workloads apply ~3 min, deployment rollouts ~2 min, DB seed + KB ingest ~3 min.
:::

## Re-runs and recovery

Every step is idempotent — re-running a tier converges what's missing and skips what's already done. If a step fails the script hard-stops on it and prints a `Fix:` hint; fix the cause and re-run the same `--tier N` command.

When the cluster, images, and Vault init are already done, the slow stages can be skipped on a tier-1 re-run:

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1 --skip-infra --skip-build --skip-vault-init
```

Tier-1 outputs referenced by later pages: `kubectl_config_command`, `kb_id`, `rds_endpoint`.
