---
title: 'Deploy Workspace'
weight: 31
---

The bootstrap script already created the HCP Terraform Workspace, agent pool, and agent token. In this step, you start the local tfc-agent, push to `main` to trigger the first workspace plan, approve the apply, and then run `configure-workshop.sh` to complete post-deploy configuration.

## Step 1 — Start the tfc-agent

The HCP Terraform Workspace is configured to use your local agent pool. Start the agent in a dedicated terminal — keep it running throughout the workshop:

```bash
export TFC_AGENT_TOKEN=$(cat infrastructure/scripts/.agent-token)
tfc-agent
```

You should see:

```
INFO agent: Starting agent
INFO agent: Connected to HCP Terraform
INFO agent: Waiting for jobs
```

:::alert{header="Agent token location" type="info"}
The `.agent-token` file was created by `bootstrap.sh` when it provisioned the agent pool. It is gitignored — never commit it. If the file is missing, re-run `bootstrap.sh --mode workspace` to regenerate it.
:::

## Step 2 — Push to trigger the workspace plan

Push any change to `main` to trigger the first workspace plan. If you have no local changes, you can trigger from the HCP Terraform UI instead (see the alert below).

```bash
git push origin main
```

HCP Terraform detects the push and queues a new run in the workspace. Your local tfc-agent picks up the run and begins planning against your AWS account.

:::alert{header="Triggering from the UI instead" type="info"}
If you have no local changes to push, you can trigger a run manually: go to [HCP Terraform](https://app.terraform.io/) > your Project > your Workspace > **Actions** > **Start new run**. Select **Plan and apply** and confirm.
:::

## Step 3 — Review and approve the plan

In the HCP Terraform UI, navigate to the running plan:

1. Go to [HCP Terraform](https://app.terraform.io/) > your Project > your Workspace
2. Click the active run
3. Review the plan — expect ~80–120 resource additions
4. Click **Confirm & Apply**

:::alert{header="First deploy timing" type="info"}
Total time: ~25–35 minutes (EKS ~12 min, RDS ~10 min including pgaudit reboot, Bedrock KB ~3 min, addons ~5 min). The tfc-agent must remain running in your terminal throughout.
:::

## Step 4 — Run configure-workshop.sh

After the workspace apply completes, run the post-deploy configuration script. This configures kubectl, initializes and configures Vault, configures IVIA, and seeds the banking database:

```bash
bash infrastructure/scripts/configure-workshop.sh
```

The script prints a pass/fail summary for each configuration step. All steps must pass before continuing to the verification module.

:::alert{header="Script is idempotent" type="info"}
`configure-workshop.sh` is safe to re-run at any point. If a step fails, fix the root cause and re-run — already-completed steps are skipped or produce the same outcome.
:::

## What Happens During Apply

When the workspace apply runs, HCP Terraform deploys the eleven modules in dependency order:

1. **audit** + **vpc** + **bedrock_kb_aoss** — apply in parallel (no inter-dependencies)
2. **eks** — depends on `vpc` + `audit`
3. **addons** + **rds** — depend on `eks`
4. **bedrock_kb_index** — depends on `bedrock_kb_aoss`
5. **vault** + **ivia** — depend on `eks` + `addons` (ALB webhook ready)
6. **vault_config** + **isva_config** — depend on Vault running
7. **uc1_agent** + **uc2_app** — depend on `vault_config`

When the run completes, note these outputs — you will need them in the next sub-modules:

- `kubectl_config_command` — the `aws eks update-kubeconfig` one-liner
- `knowledge_base_id` — the Bedrock KB ID for ingestion
- `rds_endpoint` — the PostgreSQL connection endpoint

## Module Reference

::::expand{header="audit — Encryption and observability foundation"}
- Workshop CMK (`alias/workshop-data`) — encrypts all storage across all modules
- CloudWatch log groups — `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace` (KMS-encrypted, 7-day retention)
- Glue catalog database `workshop_logs` + Athena workgroup `workshop`
::::

::::expand{header="vpc — Network substrate"}
- VPC `10.1.0.0/16`, 3 public + 3 private subnets across 3 AZs
- Single NAT Gateway, S3 gateway endpoint
- 6 interface endpoints: `bedrock-runtime`, `bedrock-agent-runtime`, `logs`, `sts`, `secretsmanager`, `kms`
::::

::::expand{header="eks — Kubernetes cluster and managed addons"}
- Kubernetes 1.33 cluster, 3 × m5.xlarge managed node group (AL2023)
- 5 control-plane log types, EKS Access Entry for your `admin_principal_arn`
- 5 managed addons: `vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent`, `aws-ebs-csi-driver`
::::

::::expand{header="addons — External cluster addons"}
- cert-manager, external-dns, AWS Load Balancer Controller (via eks-blueprints-addons)
::::

::::expand{header="rds — PostgreSQL 17 with audit logging"}
- PostgreSQL 17 (`db.t3.medium`), pgaudit + connection logging, storage-encrypted with workshop CMK
- Master password managed by Secrets Manager, security group admits `:5432` from EKS only

**Note:** `shared_preload_libraries = pgaudit` is a static parameter group setting — RDS reboots at apply time (~10 min).
::::

::::expand{header="bedrock_kb_aoss — Knowledge Base infrastructure (us-east-1)"}
- KB CMK, AOSS VECTORSEARCH collection `workshop-kb`, 3 AOSS policies
- IAM service role (5 inline policies), S3 corpus + multimodal buckets
- 8 synthetic markdown files across 3 domains (HR, customers, finance)
::::

::::expand{header="bedrock_kb_index — Knowledge Base and data sources (us-east-1)"}
- OpenSearch index (Nova 2 Embeddings, 1024-dim, k-NN L2)
- Bedrock Knowledge Base `workshop-kb`, 3 data sources
::::
