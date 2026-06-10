---
title: 'Deploy the Workshop'
weight: 31
---

One command deploys the whole workshop. `deploy-workshop.sh` provisions all three Terraform tiers and runs every post-deploy configuration step — you never run `terraform apply` by hand.

The deploy is split into three local-state roots, applied in dependency order. Each downstream root reads the upstream root's state, so Terraform enforces the order for you:

- **Tier 1** — `infrastructure/` — VPC, EKS, add-ons, RDS, Bedrock Knowledge Base, ECR, IAM
- **Tier 2** — `infrastructure/services/` — Vault server + IBM Verify Identity Access
- **Tier 3** — `infrastructure/workloads/` — the Use Case 1, 2, and 3 agent pods

## Step 1 — Confirm the roots are initialized

`bootstrap.sh` already ran `terraform init` in all three roots. If you skipped it, init them now:

```bash
terraform -chdir=infrastructure init && terraform -chdir=infrastructure/services init && terraform -chdir=infrastructure/workloads init
```

## Step 2 — Deploy

```bash
bash infrastructure/scripts/deploy-workshop.sh
```

The script prints a pass/fail summary per step. Every step must pass before you continue to verification.

:::alert{header="Timing & re-runs" type="info"}
First deploy takes ~35–50 min (EKS ~12, RDS ~10 incl. pgaudit reboot, Bedrock KB ~3, add-ons ~5, then Vault + IVIA + ACME + workloads) — timing tracks AWS API response, not your machine. The script is idempotent: if a step fails, fix the cause and re-run; converged work is skipped.
:::

:::alert{header="If a step fails — resume without redoing the slow stages" type="warning"}
The script hard-stops on the first failed step and prints a `Fix:` hint. Fix the cause (for example, **start Docker Desktop** if the image build failed), then resume. Once the cluster, images, and Vault init are already done, skip those slow stages and re-run the configuration steps:

```bash
bash infrastructure/scripts/deploy-workshop.sh --skip-infra --skip-vault-init --skip-build
```

This re-applies Tier 2 (no-op if unchanged), re-runs the ACME/issuer patch, then **Configure Vault** and everything after it. Re-running is always safe — converged work is skipped. **Configure Vault** retries the Vault connection for up to 30s and tolerates a standby Raft node; a persistent "Cannot reach Vault" means the Vault pods aren't all `Running` yet — check `kubectl -n vault get pods`, then re-run the command above.
:::

## What it runs, in order

1. **Apply tier-1** — VPC, EKS, add-ons (cert-manager, external-dns, AWS Load Balancer Controller), RDS, Bedrock KB, ECR, IAM, audit substrate. *No pods yet.*
2. **Configure kubectl** (`aws eks update-kubeconfig`)
3. **Build & push** the Use Case 1/2/3 images (`build-images.sh`)
4. **Load Balancer Controller readiness gate**
5. **Apply tier-2** — Vault server + IVIA
6. **Initialize Vault** (`vault-init.sh`) — writes `~/vault-init.json`
7. **Issue ACME cert**, sync to ACM, re-apply IVIA on the trusted `nip.io` host
8. **Configure Vault** (`vault-configure.sh`) — auth, policies, secrets engines
9. **Configure IVIA** (`ivia-configure.sh`) — verify OIDC discovery
10. **Apply tier-3** — Use Case agent pods, then roll deployments
11. **Shared-ALB assertion** + IVIA redirect reconcile
12. **Verify** OpenLDAP user `oscar` was seeded
13. **Seed the banking database** (`seed-banking-db.sh`)
14. **Ingest the Bedrock KB corpus** (`sync-bedrock-kb.sh`)

Tier-1 outputs referenced later: `kubectl_config_command`, `kb_id`, `rds_endpoint`.
