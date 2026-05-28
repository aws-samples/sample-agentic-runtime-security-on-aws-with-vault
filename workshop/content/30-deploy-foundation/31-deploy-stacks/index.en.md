---
title: 'Terraform Apply'
weight: 31
---

Terraform state is stored locally under `infrastructure/terraform.tfstate`. In this step, you run `terraform apply` locally to deploy all foundation infrastructure, then run `configure-workshop.sh` to complete post-deploy configuration.

## Step 1 — Initialize Terraform

Initialize the working directory to download providers and modules. Run this once before your first apply:

```bash
terraform -chdir=infrastructure init
```

## Step 2 — Run terraform apply

```bash
terraform -chdir=infrastructure apply -auto-approve
```

Terraform provisions ~80-120 resources. `-auto-approve` skips the interactive confirmation.

:::alert{header="First deploy timing" type="info"}
Total time: ~25-35 minutes (EKS ~12 min, RDS ~10 min including pgaudit reboot, Bedrock KB ~3 min, addons ~5 min). The apply runs locally but provisions AWS resources remotely — timing depends on AWS API response times, not your machine.
:::

## Step 3 — Run configure-workshop.sh

After the apply completes, run the post-deploy configuration script. It performs six steps in order:

1. Configure kubectl (`aws eks update-kubeconfig`)
2. Initialize Vault (`vault-init.sh`) — writes `~/vault-init.json` with the root token and unseal keys
3. Configure Vault (`vault-configure.sh`) — auth methods, policies, secrets engines
4. Configure IVIA (`ivia-configure.sh`) — verifies OIDC discovery is responding
5. Verify the workshop user `oscar` was seeded into the in-cluster OpenLDAP directory by the IVIA autoconf job
6. Seed the banking database (`seed-banking-db.sh`)

```bash
bash infrastructure/scripts/configure-workshop.sh
```

The script prints a pass/fail summary for each configuration step. All steps must pass before continuing to the verification module.

:::alert{header="Script is idempotent" type="info"}
`configure-workshop.sh` is safe to re-run at any point. If a step fails, fix the root cause and re-run — already-completed steps are skipped or produce the same outcome.
:::

## What is Provisioned

You don't sequence this yourself; Terraform's dependency graph handles ordering. Broadly, resources flow through these waves:

1. **Networking, audit & registry foundation** — `vpc`, `audit`, `ecr`
2. **EKS cluster** — `eks` (needs the VPC)
3. **Cluster add-ons & data services** — `addons` (cert-manager, external-dns, AWS Load Balancer Controller), `rds`, and the Bedrock Knowledge Base
4. **HashiCorp Vault** — needs the add-ons (ALB controller / cert-manager) ready
5. **IBM Verify Access** — needs the ALB controller webhook ready
6. **Vault configuration** — auth methods, policies, secrets engines (needs Vault running)
7. **Use-case workloads** — the Use Case 1, 2, and 3 agent pods (need Vault configured)

When the apply completes, note these outputs — you will need them in the next sub-modules:

- `kubectl_config_command` — the `aws eks update-kubeconfig` one-liner
- `kb_id` — the Bedrock KB ID for ingestion
- `rds_endpoint` — the PostgreSQL connection endpoint
