---
title: 'Deploy Stacks'
weight: 31
---

The bootstrap script already created the HCP Terraform Stack and connected it to your GitHub repository. In this step, you will trigger the first deployment, which creates the VPC, EKS, RDS, Bedrock KB, and audit foundation in dependency order.

## Trigger the First Plan

The Stack watches the `main` branch on **your fork**. The first plan must be triggered manually from the HCP Terraform UI — pushes alone do not initialize a brand-new Stack configuration.

1. Go to [HCP Terraform](https://app.terraform.io/) > your Project > your Stack
2. Click **New configuration** (or **New plan** > **Start** if a configuration already exists)
3. Select the `main` branch and confirm

Subsequent runs are triggered automatically by pushing to `main` on your fork:

```bash
# make a change, e.g. edit a comment in deployments.tfdeploy.hcl
git add infrastructure/deployments.tfdeploy.hcl
git commit -m "trigger plan"
git push origin main
```

:::alert{header="Push not triggering a plan?" type="warning"}
If `git push origin main` does not produce a new run in HCP Terraform, verify:
- Your `origin` remote points at **your fork** (`git remote -v`), not the upstream repo
- The Stack's VCS settings in HCP Terraform reference your fork and the `main` branch
- The GitHub VCS connection in your HCP Terraform org has access to your fork
:::

## Review and Apply

HCP Terraform will automatically:

- Detect the `usw2` deployment from `deployments.tfdeploy.hcl` (the only deployment with `destroy = false`)
- Create a plan — expect ~80–120 resource creations across seven components
- Wait for your approval before applying

Review the plan and click **Approve & Apply**.

:::alert{header="First deploy behavior — deferred items" type="info"}
On first deploy, you will see "deferred items" in the plan. This is expected — Helm and Kubernetes providers defer planning until EKS outputs are available (the cluster endpoint does not exist yet). Apply the plan and a second run will handle the deferred items automatically.
:::

## What Happens During Apply

When you approve the plan, HCP Terraform deploys the seven components in dependency order:

1. **audit** + **vpc** + **bedrock_kb_aoss** — apply in parallel (no inter-dependencies)
2. **eks** — depends on `vpc` + `audit`
3. **addons** + **rds** — depend on `eks`
4. **bedrock_kb_index** — depends on `bedrock_kb_aoss`

Total time: ~25–35 minutes (EKS ~12 min, RDS ~10 min including pgaudit reboot, Bedrock KB ~3 min, addons ~5 min).

:::alert{header="Expect multiple plan/apply rounds" type="warning"}
Stacks runs a **deferred-replan** loop: after the first apply, components whose inputs become resolvable (e.g. `bedrock_kb_index` waiting on the AOSS collection endpoint) get re-planned and you'll be prompted to **Approve** again. A clean first deploy typically goes through **3–5 plan/apply rounds** before the run reaches `succeeded`.

Don't walk away after the first apply. The run isn't done until the status flips from `deploying` to `succeeded`.
:::

When the run completes, note these outputs — you will need them in the next sub-modules:

- `kubectl_config_command` — the `aws eks update-kubeconfig` one-liner
- `knowledge_base_id` — the Bedrock KB ID for ingestion
- `rds_endpoint` — the PostgreSQL connection endpoint

## Component Reference

::::expand{header="audit — Encryption and observability foundation"}
- Workshop CMK (`alias/workshop-data`) — encrypts all storage across all components
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
