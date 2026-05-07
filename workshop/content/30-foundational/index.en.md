---
title: 'Foundational Infrastructure'
weight: 30
---

## Overview

In this module you deploy the AWS foundation that hosts the entire Agentic Runtime Security workshop in a single region: a VPC, an Amazon EKS cluster sized to host (but not yet running) HashiCorp Vault + IBM Verify Identity Access + the three demo agent pods, an Amazon RDS PostgreSQL 17 instance, an Amazon Bedrock Knowledge Base on OpenSearch Serverless, and the audit-correlation foundation (workshop CMK, three CloudWatch log groups, Glue catalog database, Athena workgroup) that every later phase joins against.

You deploy it as **one Terraform Stacks configuration** with **seven components** wired through HCP Terraform: `audit`, `vpc`, `eks`, `addons`, `rds`, `bedrock_kb_aoss`, `bedrock_kb_index`. A single `terraform stacks apply` builds the entire substrate. (The Bedrock Knowledge Base is split across two components — `_aoss` owns the AOSS collection / IAM / S3 corpus, `_index` owns the vector index + KB + data sources — to avoid a Stacks circular dependency between the opensearch provider URL and the component that creates the AOSS endpoint.)

Vault, IBM Verify Identity Access, and the agent pods are **not** installed in this phase — Phase 3 owns those workloads. Phase 2's job is to make sure the substrate is correct, the audit-correlation contract is locked, and `kubectl get nodes` returns three Ready nodes.

## Reference architecture

![Reference architecture](/static/images/02-reference-architecture.svg)

The diagram above shows the seven Phase 2 components and how they wire together. Three of the seven (`audit`, `vpc`, `bedrock_kb_aoss`) have no inter-component dependencies inside Phase 2 — they apply in parallel as Wave 0/1. The other four layer on top: `eks` depends on `vpc` + `audit`; `rds` depends on `vpc` + `audit` + `eks`; `bedrock_kb_index` depends on `bedrock_kb_aoss`; `addons` depends on `eks`.

## The audit-correlation contract (load-bearing)

Before any workload lands on this cluster, the workshop pays its **audit-correlation design tax**. Phase 2 ships:

- **One workshop CMK** (`alias/workshop-data`) that encrypts RDS storage, OpenSearch Serverless data, the S3 corpus bucket, and every CloudWatch log group across all seven components — one key, one encryption-context story.
- **Three pre-created CloudWatch log groups** that Phase 3 fluent-bit DaemonSets ship logs into by ARN: `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace`.
- **A Glue catalog database** (`workshop_logs`) and **Athena workgroup** (`workshop`) that Phase 6's UC3 audit-correlation query runs against.

The cross-plane correlation key is **W3C Trace Context** (`traceparent` / 16-byte `trace-id`). The agent generates it via Strands' OpenTelemetry SDK, propagates it to Vault (`X-Vault-Request-Id`), to IBM Verify Identity Access (`X-Request-Id`), to the database (`application_name` on the psycopg connection), and to Bedrock (Strands span). For the AWS plane — where CloudTrail does not carry `traceparent` — a composite-key bridge joins on `(principal + ±5s timestamp window)`.

**Read this once before deploying:** [`infrastructure/docs/audit-correlation-queries.md`](https://github.com/IBM/agentic-runtime-security-aws/blob/main/infrastructure/docs/audit-correlation-queries.md). It contains the canonical contract diagram, the field-by-field log source table, and the full Athena composite-key JOIN template you will return to in Phase 6's audit-correlation exercise.

:::alert{header="Why this matters now" type="info"}
Trying to retrofit cross-plane audit correlation after agents and Vault are running is effectively impossible — every plane stamps a different correlation field, log groups inherit the wrong KMS key, and the JOIN never resolves. Phase 2 deliberately fronts the cost: one CMK, pre-created log groups, the trace-id contract written down in code review before anyone writes agent code.
:::

## Pre-flight prerequisites

Confirm you completed Phase 1's [Prerequisites module](../20-prerequisites/) before deploying:

- Amazon Bedrock Nova Pro (`us.amazon.nova-pro-v1:0` cross-region inference profile) and Titan Embeddings v2 (`amazon.titan-embed-text-v2:0`) are **enabled** in your AWS account.
- EC2, Elastic IP, and OpenSearch Serverless quotas are sufficient for the workshop topology (a single NAT Gateway EIP, three m5.xlarge nodes, and 2 OCU minimum on AOSS).
- An HCP Terraform organization and project are bootstrapped, with a variable set carrying your `admin_principal_arn` (the IAM principal that becomes the EKS cluster admin via Access Entries).

If any item is missing, return to the Prerequisites module — Phase 2 will fail at apply time without all three.

## Component-by-component walkthrough

The Stacks deployment applies the components in this order. Each subsection below tells you (a) what the component creates, (b) what AWS resources to expect, and (c) the **"What you just deployed"** summary you will see in the HCP Terraform run output.

### 1. Audit foundation (`audit` component)

The `audit` component is the load-bearing Phase 2 deliverable. It applies first (Wave 0) and creates:

- The workshop **customer-managed KMS key** (`alias/workshop-data`) that every other component reuses for storage encryption.
- The three **pre-created CloudWatch log groups** that fluent-bit ships into in Phase 3:
  - `/workshop/vault-audit` — Vault audit device output.
  - `/workshop/ivia-decision` — IBM Verify Identity Access decision logs.
  - `/workshop/agent-trace` — agent OTel spans (`traceparent` field).
- The Glue catalog database `workshop_logs` (empty in Phase 2; Phase 6 adds tables).
- The Athena workgroup `workshop` with KMS-encrypted query results in `s3://workshop-athena-<random>/results/`.

:::alert{header="What you just deployed (audit)" type="success"}
- **KMS CMK** — `alias/workshop-data` (rotation enabled, key policy grants encrypt/decrypt to RDS, AOSS, S3, CloudWatch Logs service principals)
- **CloudWatch log groups** — `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace` (all KMS-encrypted with the workshop CMK, 7-day retention)
- **Glue catalog database** — `workshop_logs`
- **Athena workgroup** — `workshop`
- **S3 bucket** — `workshop-athena-<random>` (Athena query results, SSE-KMS with the workshop CMK)
:::

### 2. VPC (`vpc` component)

The `vpc` component wraps `terraform-aws-modules/vpc/aws ~> 5.16` to create the workshop's network substrate:

- **3 public + 3 private subnets** across 3 Availability Zones.
- **Single NAT Gateway** (cost-optimized for an ephemeral workshop — about $70/mo cheaper than per-AZ NAT).
- **S3 gateway endpoint** — free; required so Bedrock model artifact pulls and KB ingestion stay on the AWS backbone.
- **6 interface endpoints** — `bedrock-runtime`, `bedrock-agent-runtime`, `logs`, `sts`, `secretsmanager`, `kms`. These demonstrate that the agent → Bedrock + Vault → KMS + audit → CloudWatch Logs paths never traverse the NAT.
- **Subnet tags** — `kubernetes.io/role/elb=1` on public subnets, `kubernetes.io/role/internal-elb=1` on private subnets, so the AWS Load Balancer Controller (deployed in component 4) can discover them.

OpenSearch Serverless is intentionally left **public** — there is no `aoss` interface endpoint. AOSS access is governed by the AOSS network policy, not VPC routing.

:::alert{header="What you just deployed (vpc)" type="success"}
- **VPC** — `10.1.0.0/16`, 3 AZs
- **Public subnets** — 3 (tagged `kubernetes.io/role/elb=1`)
- **Private subnets** — 3 (tagged `kubernetes.io/role/internal-elb=1`)
- **NAT Gateway** — single, public-subnet-anchored
- **S3 gateway endpoint** — attached to all private route tables
- **Interface endpoints** — 6: `bedrock-runtime`, `bedrock-agent-runtime`, `logs`, `sts`, `secretsmanager`, `kms` (security group admits 443/tcp from VPC CIDR only)
:::

### 3. EKS cluster (`eks` component)

The `eks` component wraps `terraform-aws-modules/eks/aws ~> 20.37` plus `terraform-aws-modules/eks-pod-identity/aws ~> 1.12` (twice — once each for `vpc-cni` and `aws-ebs-csi-driver`). The `eks/aws 21.x` and `eks-pod-identity 2.x` series both require AWS provider 6.x; this workshop pins AWS provider `~> 5.0` to match the eks-terraform-stacks reference, so we stay on the latest 1.x / 20.x lines that retain AWS-5 compatibility. It creates:

- **Kubernetes 1.33** control plane in the private subnets.
- **Managed node group** — m5.xlarge × **desired=3 / min=2 / max=5**, AL2023, on-demand. (Karpenter is **out of scope** for this workshop — the cluster runs with a managed node group only.)
- **All 5 control-plane log types** enabled: `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`.
- **EKS Access Entries** — your `admin_principal_arn` is granted `AmazonEKSClusterAdminPolicy` (replaces the legacy `aws-auth` ConfigMap).
- **5 managed cluster addons** — `vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent`, `aws-ebs-csi-driver`. The two addons that need IAM (`vpc-cni`, `aws-ebs-csi-driver`) use **EKS Pod Identity Associations**, not IRSA.
- **`before_compute = true`** on `vpc-cni` and `eks-pod-identity-agent` — so nodes can pull pod-network IPs and Pod Identity tokens before they bootstrap.

:::alert{header="What you just deployed (eks)" type="success"}
- **EKS cluster** — `agentic-runtime-<region-short>`, K8s 1.33
- **Managed node group** — 3 × m5.xlarge AL2023 nodes (desired=3, min=2, max=5)
- **Control-plane log group** — `/aws/eks/<cluster>/cluster` (all 5 log types)
- **Access Entry** — `admin_principal_arn` → `AmazonEKSClusterAdminPolicy`
- **Managed addons (5)** — `vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent`, `aws-ebs-csi-driver` (Pod Identity Associations on `vpc-cni` + `aws-ebs-csi-driver`)
- **Output** — `kubectl_config_command` (the one-liner you run below)
:::

### 4. Cluster addons (`addons` component)

The `addons` component layers the three **external** (non-managed) cluster addons that Phase 3+ assumes exist, via `aws-ia/eks-blueprints-addons ~> 1.0`:

- **cert-manager** — TLS issuer for Vault, IVIA, and ALB-fronted Services. Default `selfsigned` ClusterIssuer ships at install; Vault PKI integration is deferred to Phase 3+.
- **external-dns** — automatic Route53 record management for ALB-fronted Services. Required so attendee-visible URLs work without manual DNS.
- **AWS Load Balancer Controller** — provisions ALBs from Kubernetes Ingress. `replicaCount=2` keeps the mutating webhook reachable across pod restarts.

The Helm provider in this module is pinned **`~> 2.17`** (NOT 3.x) — the `eks-blueprints-addons` `helm_release` shape is incompatible with helm provider 3.x as of pin time.

:::alert{header="What you just deployed (addons)" type="success"}
- **cert-manager** — namespace `cert-manager`, default `selfsigned` ClusterIssuer
- **external-dns** — namespace `external-dns`, IRSA-bound for Route53 R/W
- **AWS Load Balancer Controller** — namespace `kube-system`, IRSA-bound, replicaCount=2
:::

### 5. RDS PostgreSQL 17 (`rds` component)

The `rds` component creates a single-AZ PostgreSQL 17 instance with audit logging enabled in Phase 2 — not deferred — so Phase 3+ Vault PostgreSQL secrets engine just works:

- **Engine** — PostgreSQL 17, instance class `db.t3.medium` (default; bump to `db.t3.large` for >15 attendees).
- **pgaudit + connection logging** enabled via custom parameter group: `shared_preload_libraries = pgaudit`, `pgaudit.log = ddl,write,role`, `log_connections = 1`, `log_disconnections = 1`.
- **CloudWatch log exports** — `postgresql` + `upgrade`. Pre-created log group `/aws/rds/instance/<id>/postgresql` is encrypted with the workshop CMK.
- **Master password** — managed by RDS to AWS Secrets Manager (`manage_master_user_password = true`), encrypted with the workshop CMK. Bootstrap-only — Vault is the runtime credential broker.
- **Storage encryption** — workshop CMK.
- **Network** — private subnets only, security group admits `:5432` only from the EKS cluster security group.

:::alert{header="First-apply note (~10 min for pgaudit reboot)" type="warning"}
`shared_preload_libraries = pgaudit` is a **static** parameter group setting. RDS must reboot to load the library, and `apply_immediately = true` makes the reboot happen at apply time rather than the next maintenance window. Total RDS apply time: ~10 minutes. If you connect immediately after apply and `SHOW shared_preload_libraries;` returns empty, the reboot has not finished — wait for the instance to return to `available`.
:::

:::alert{header="What you just deployed (rds)" type="success"}
- **RDS instance** — `workshop-pg17`, PostgreSQL 17, `db.t3.medium`, single-AZ, storage-encrypted with the workshop CMK
- **Parameter group** — pgaudit + connection logging
- **CloudWatch log group** — `/aws/rds/instance/workshop-pg17/postgresql` (workshop CMK)
- **Master password** — Secrets Manager secret managed by RDS, encrypted with the workshop CMK
- **DB security group** — admits `:5432` from the EKS cluster security group only
:::

### 6. Bedrock Knowledge Base (`bedrock_kb_aoss` + `bedrock_kb_index` components)

The Bedrock Knowledge Base is the highest-risk-surface part of Phase 2 — it stitches together six interlocking AWS resources with strict ordering plus a synthetic corpus, **split across two Stacks components**:

- **`bedrock_kb_aoss`** — owns the AOSS collection, the 3 AOSS policies, the IAM service role, the S3 corpus bucket, and the IAM-propagation `time_sleep`. Does NOT use the opensearch provider.
- **`bedrock_kb_index`** — owns the OpenSearch vector index, the Bedrock Knowledge Base resource, and the 3 data sources. USES the opensearch provider.

**Why split?** The Stack-level opensearch provider's `url` must reference the AOSS collection endpoint (`component.bedrock_kb_aoss.aoss_collection_endpoint`). If the same component that creates the collection also used that provider, Stacks would detect a `provider → component → provider` cycle and reject the configuration. Splitting breaks the cycle: `bedrock_kb_aoss` produces the endpoint output (no opensearch provider), `bedrock_kb_index` consumes the provider (no opensearch provider self-reference).

The combined six-resource dance:

- **3 AOSS policies** — encryption (workshop CMK), network (PUBLIC), data access (KB role + apply principal).
- **AOSS VECTORSEARCH collection** — `workshop-kb`.
- **OpenSearch index** — Titan v2 embedding, **dimension 1024** (NOT 1536). Created via the `opensearch-project/opensearch` provider pinned **EXACT `= 2.2.0`** (Pitfall B3).
- **IAM service role** + 4 inline policies (aoss / s3 / bedrock / kms).
- **`time_sleep` 20s** — IAM eventual-consistency bridge (Pitfall B1).
- **Bedrock Knowledge Base** — Titan Embeddings v2 (`amazon.titan-embed-text-v2:0`).
- **3 data sources** — one per domain: HR (UC1), customers (UC2), finance (UC3).
- **S3 corpus bucket** — `workshop-kb-corpus-<random>`, SSE-KMS with the workshop CMK, holds **8 synthetic markdown files** (every file ends with the disclaimer `*Synthetic workshop content; not from any real company.*` and email addresses use the RFC 6761 reserved `example.invalid` TLD).

**Triggering ingestion** is a one-time post-apply step (see "Validating the Bedrock KB ingestion" below).

:::alert{header="What you just deployed (bedrock_kb_aoss + bedrock_kb_index)" type="success"}
- **AOSS collection** — `workshop-kb` (VECTORSEARCH, encrypted with the workshop CMK)
- **OpenSearch index** — `workshop-kb-index` (Titan v2, 1024-dim, k-NN cosine)
- **Bedrock Knowledge Base** — `workshop-kb`
- **Data sources** — 3 (HR / customers / finance)
- **S3 corpus bucket** — `workshop-kb-corpus-<random>` with 8 synthetic markdown files
- **IAM service role** — `workshop-kb-role` (4 inline policies: aoss, s3, bedrock, kms)
:::

## Deploying via HCP Terraform

The full Stacks deployment is driven from HCP Terraform, not the local CLI. The Stacks configuration uses two files at `infrastructure/`:

- `components.tfcomponent.hcl` — the seven component definitions; ordering is implicit via component-output references in `inputs` (the only explicit `depends_on` is `bedrock_kb_index → bedrock_kb_aoss`, which documents the IAM-propagation `time_sleep` barrier).
- `deployments.tfdeploy.hcl` — the **single source of truth for the canonical region** and the deployment-time inputs (`region`, `cluster_name`, `vpc_cidr`, `azs`).

Step-by-step deploy:

1. From the HCP Terraform UI, navigate to the project bootstrapped in Phase 1.
2. The Stacks configuration auto-detects from the connected VCS repository (or upload the `infrastructure/` directory directly).
3. Verify the workspace inputs from `deployments.tfdeploy.hcl` are picked up: `region`, `cluster_name`, `vpc_cidr`, `azs`. The `admin_principal_arn` comes from the variable set bootstrapped in Phase 1.
4. Click **Plan**. Review the resource graph — expect ~80–120 resource creations.
5. Click **Apply**. Total time is ~25–35 minutes (EKS ~12 min, RDS ~10 min including the pgaudit reboot, Bedrock KB ~3 min, addons ~5 min).

When the apply completes, the run output exposes the outputs you use in the next sections — especially `kubectl_config_command`, `knowledge_base_id`, and the data-source ID map.

## Configuring kubectl (INFR-05)

The `eks` module emits a one-liner output. Copy it from the HCP Terraform run output (or read it from `terraform-stacks output`):

```bash
aws eks update-kubeconfig \
  --region <REGION> \
  --name <CLUSTER_NAME> \
  --alias workshop
```

Substitute `<REGION>` and `<CLUSTER_NAME>` from the run output, then verify:

```bash
kubectl get nodes
```

**Expected output** — three nodes in `Ready` state:

```
NAME                                       STATUS   ROLES    AGE   VERSION
ip-10-1-1-xxx.<region>.compute.internal    Ready    <none>   5m    v1.33.x-eks-xxxx
ip-10-1-2-xxx.<region>.compute.internal    Ready    <none>   5m    v1.33.x-eks-xxxx
ip-10-1-3-xxx.<region>.compute.internal    Ready    <none>   5m    v1.33.x-eks-xxxx
```

If a node is `NotReady`, check the `vpc-cni` Pod Identity Association — the most common failure is `before_compute` ordering when a manual reapply skips the Pod Identity Agent.

## Attendee verification

Run all four checks below before continuing to Phase 3. They map 1:1 to the four Phase 2 infrastructure requirements (INFR-02, INFR-02 addons, INFR-03, INFR-04).

### Check 1 — EKS cluster is ACTIVE (INFR-02)

```bash
aws eks describe-cluster \
  --name <CLUSTER_NAME> \
  --region <REGION> \
  --query 'cluster.status' \
  --output text
```

**Expected output:** `ACTIVE`

### Check 2 — Nodes are Ready (INFR-02 + INFR-05)

```bash
kubectl get nodes
```

**Expected:** 3 nodes, all `Ready`. (The exact one-liner you ran in the previous section.)

### Check 3 — RDS PostgreSQL 17 is available (INFR-03)

```bash
aws rds describe-db-instances \
  --region <REGION> \
  --query 'DBInstances[?DBInstanceIdentifier==`workshop-pg17`].[DBInstanceStatus,Engine,EngineVersion]' \
  --output text
```

**Expected output:** `available  postgres  17.x`

To confirm pgaudit is loaded (requires connectivity to RDS via SSM session manager / bastion):

```bash
psql -h <RDS_ENDPOINT> -U vault_root -d workshop -c "SHOW shared_preload_libraries;"
```

**Expected output:** `pgaudit`

### Check 4 — Bedrock Knowledge Base is ACTIVE (INFR-04)

```bash
aws bedrock-agent get-knowledge-base \
  --knowledge-base-id <KB_ID> \
  --region <REGION> \
  --query 'knowledgeBase.status' \
  --output text
```

**Expected output:** `ACTIVE`

`<KB_ID>` is in the run output as `knowledge_base_id`.

### Check 5 — Audit log groups exist with the workshop CMK

```bash
aws logs describe-log-groups \
  --log-group-name-prefix /workshop \
  --region <REGION> \
  --query 'logGroups[].[logGroupName,kmsKeyId]' \
  --output table
```

**Expected output:** three rows — `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace` — each with a `kmsKeyId` ending in `:alias/workshop-data` (or the equivalent key ARN).

## Validating the Bedrock KB ingestion

The `aws_bedrockagent_data_source` resources create the binding between the KB and the S3 corpus, but they do **not** run the ingestion. Trigger one ingestion job per data source:

```bash
KB_ID=<knowledge_base_id from run output>
REGION=<region from run output>

for DS in $(aws bedrock-agent list-data-sources \
              --knowledge-base-id "$KB_ID" \
              --region "$REGION" \
              --query 'dataSourceSummaries[].dataSourceId' \
              --output text); do
  aws bedrock-agent start-ingestion-job \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS" \
    --region "$REGION"
done
```

Wait ~5 minutes, then confirm each ingestion job completed:

```bash
for DS in $(aws bedrock-agent list-data-sources \
              --knowledge-base-id "$KB_ID" \
              --region "$REGION" \
              --query 'dataSourceSummaries[].dataSourceId' \
              --output text); do
  echo "=== Data source $DS ==="
  aws bedrock-agent list-ingestion-jobs \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS" \
    --region "$REGION" \
    --query 'ingestionJobSummaries[0].[status,startedAt]' \
    --output text
done
```

**Expected output:** every line ends with `COMPLETE` and a recent `startedAt` timestamp. If any data source returns `FAILED`, check that the corpus S3 objects uploaded successfully (`aws s3 ls s3://<corpus-bucket>/`) and the KB role has `s3:GetObject` on the bucket.

## Region contract validation (ROADMAP success criterion #3)

The workshop has a hard rule: **no canonical-region string literal anywhere in `infrastructure/` outside `deployments.tfdeploy.hcl`**. Every module interpolates `var.region`. Confirm the rule holds by exporting your canonical region and grepping:

```bash
export CANONICAL_REGION=<your region from deployments.tfdeploy.hcl>

grep -rn "$CANONICAL_REGION" \
  --include='*.tf' \
  --include='*.hcl' \
  --include='*.tfcomponent.hcl' \
  --include='*.tfdeploy.hcl' \
  infrastructure/ | grep -v deployments.tfdeploy.hcl
```

**Expected output:** **nothing** (zero matches). A non-empty result means a region literal leaked into a module — fix it before continuing to Phase 3.

## What you just deployed (Phase 2 summary)

A single HCP Terraform Stacks apply just created, in dependency order:

| Component    | Key resources                                                                                                                       |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `audit`      | Workshop CMK (`alias/workshop-data`), 3 audit log groups, Glue database `workshop_logs`, Athena workgroup `workshop`, results bucket |
| `vpc`        | VPC `10.1.0.0/16`, 3 public + 3 private subnets, single NAT, S3 gateway endpoint, 6 interface endpoints                              |
| `eks`        | Kubernetes 1.33 cluster, 3-node managed node group, 5 control-plane log types, Access Entries, 5 managed addons with Pod Identity   |
| `addons`     | cert-manager + external-dns + AWS Load Balancer Controller (helm provider 2.17)                                                     |
| `rds`        | PostgreSQL 17 single-AZ, pgaudit + connection logging, master password in Secrets Manager (workshop CMK)                            |
| `bedrock_kb_aoss`  | AOSS VECTORSEARCH collection + 3 policies, IAM service role + 4 inline policies, S3 corpus bucket (workshop CMK SSE), 8 synthetic markdown files |
| `bedrock_kb_index` | OpenSearch index (Titan v2 1024-dim, k-NN cosine), Bedrock Knowledge Base, 3 data sources (HR / customers / finance)              |

The audit-correlation contract is **locked**: every component encrypts with the workshop CMK, the three audit log groups are pre-created with the right key, and the trace-id propagation contract is documented in [`infrastructure/docs/audit-correlation-queries.md`](https://github.com/IBM/agentic-runtime-security-aws/blob/main/infrastructure/docs/audit-correlation-queries.md).

## Production-grade considerations

Several spots in this Phase 2 code are deliberately simplified to keep the workshop teach-able in a 6-hour window. **Do not copy these directly into a production deployment.** The table below names each simplification, where it lives, and the canonical production pattern. The rest of the workshop's choices — workload-identity discipline, no-standing-privileges, audit-correlation, region pinning, helm 2.17 / opensearch 2.2.0 pins, EKS 1.33 / Pod Identity — *are* production-grade.

| Workshop simplification | Where | Production pattern |
| --- | --- | --- |
| EKS API endpoint exposed to `0.0.0.0/0` | `infrastructure/modules/eks/main.tf` (`cluster_endpoint_public_access_cidrs`) | Set `cluster_endpoint_public_access = false` and rely on `cluster_endpoint_private_access = true`; reach the cluster via AWS Client VPN, a bastion, or SSM Session Manager. Or pin `_cidrs` to corporate egress / VPN exit IPs. The `0.0.0.0/0` choice is needed for Workshop Studio attendees, who arrive from random IPs. |
| AOSS network policy `AllowFromPublic = true` | `infrastructure/modules/bedrock_kb_aoss/aoss.tf` | Set `AllowFromPublic = false` and add a VPC interface endpoint (`aws_vpc_endpoint` with `service_name = "com.amazonaws.<region>.aoss"`). Reference it from the network policy via `SourceVPCEs`. Bedrock KB → AOSS traffic stays inside the VPC. |
| AOSS data-access policy uses `aoss:*` | `infrastructure/modules/bedrock_kb_aoss/aoss.tf` | Split into two principal-scoped statements: the Bedrock KB role gets `aoss:APIAccessAll` only (read/write data + ingestion), and the Stacks-runner principal gets `aoss:CreateIndex` / `aoss:UpdateIndex` / `aoss:DeleteIndex` / `aoss:DescribeIndex` (index lifecycle). Drop admin actions from both. |
| `enable_cluster_creator_admin_permissions = true` | `infrastructure/modules/eks/main.tf` | For pipeline-deployed clusters, set this to `false` and explicitly declare `access_entries` per role: platform team gets `AmazonEKSClusterAdminPolicy`, app teams get `AmazonEKSEditPolicy` scoped to namespaces, on-call gets `AmazonEKSViewPolicy`. The deploy role's access entry should be revoked post-bootstrap (Pitfall E3 — without revocation it persists and is hard to audit). |
| Deploy role attached `AdministratorAccess` | `infrastructure/scripts/setup-aws-oidc.sh` | Replace with the scoped policy from `eks-terraform-stacks/infrastructure/scripts/setup-aws-oidc.sh` lines 184–339, then iterate against your real apply log to add any missing actions. Workshop pedagogy — IAM least-privilege design — is its own multi-day topic; this workshop teaches the workload-identity layer, not IAM design. |

The workshop's deliberate stop point: it teaches **the 5 control objectives at the workload-identity / data-plane layer**. The simplifications above are at the IAM / network-perimeter layer, which a different workshop (or a Hashicorp Validated Design) would tackle.

## Next steps

Continue to **Phase 3 — Platform: Vault and IBM Verify Access**. Phase 3 will:

- Install HashiCorp Vault on EKS (3 Raft pods, one per AZ) with auto-unseal via a separate KMS key.
- Install IBM Verify Identity Access on EKS, fronted by an ALB-Ingress (provisioned by the Load Balancer Controller you just deployed).
- Wire fluent-bit DaemonSets to ship Vault audit + IVIA decision logs into the **already-pre-created** `/workshop/vault-audit` and `/workshop/ivia-decision` log groups by ARN.
- Configure the Vault `jwt` auth method to trust IVIA's OIDC discovery URL — the OIDC seam where user intent becomes a Vault-vended credential.

The audit-correlation contract you just deployed is the foundation Phase 3+ joins against. By the end of Phase 6, a single Athena query in workgroup `workshop` will JOIN all five log streams on `trace-id` and answer "which user authorized which action against which AWS API?" — the load-bearing UC3 deliverable.
