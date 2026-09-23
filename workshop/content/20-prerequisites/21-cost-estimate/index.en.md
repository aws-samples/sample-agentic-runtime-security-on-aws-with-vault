---
title: 'What It Costs'
weight: 21
---

Running this workshop in your own AWS account costs roughly **$4.20 for a 90-minute run** and **$5.40 for a two-hour run** in `us-east-1`. The clock starts when `deploy-workshop.sh` creates the first resource and stops when `teardown.sh` removes the last one.

::::alert{header="At an event: this page is background only" type="info"}
Workshop Studio vends your account and absorbs everything it runs. Nothing on this page is billed to you. Read on only if you plan to deploy the workshop into an account you own.
::::

## The two numbers

| Run length | Infrastructure | Usage & one-time | Total |
| --- | --- | --- | --- |
| 1.5 hours | $3.59 | $0.63 | **$4.21** |
| 2 hours | $4.78 | $0.63 | **$5.41** |

Both totals rest on the same hourly run rate of **$2.39/hour**. A two-hour run costs 1.28× a 90-minute run rather than the full 1.33×, because the usage block below is charged once no matter how long the stack lives.

## Where the $2.39/hour goes

Quantities are read from a real deployment of this workshop, not from a sizing guess.

| Line item | Quantity | $/hour |
| --- | --- | --- |
| EC2 `m5.xlarge` worker nodes | 5 | 0.9600 |
| OpenSearch Serverless OCUs | 4 | 0.9600 |
| Interface VPC endpoints (6 services × 3 AZs) | 18 | 0.1800 |
| EKS control plane | 1 | 0.1000 |
| RDS `db.t3.medium` PostgreSQL, Single-AZ | 1 | 0.0720 |
| NAT gateway | 1 | 0.0450 |
| Application Load Balancer | 1 | 0.0225 |
| Public IPv4 addresses (NAT + ALB) | 4 | 0.0200 |
| EBS `gp3` node root volumes | 100 GiB | 0.0110 |
| ALB capacity units | 1 LCU | 0.0080 |
| RDS `gp3` storage | 50 GB | 0.0079 |
| KMS customer-managed keys | 3 | 0.0041 |
| **Hourly run rate** | | **2.3904** |

Three of these deserve a note:

- **The node group is fixed at 5 `m5.xlarge`.** `desired_size = 5` with `min_size = 3`; the workshop runs Vault HA, a seven-pod IVIA stack, three agent workloads and the banking UI, so the nodes are sized for the peak and never scale down within a workshop-length run.
- **OpenSearch Serverless bills a 4-OCU minimum.** The collection is created with standby replicas enabled, which pins two indexing OCUs and two search OCUs regardless of how small the index is. The workshop's knowledge base holds 8 documents totalling 21 KB and would fit in a fraction of one OCU — you pay for four. At $0.24/OCU-hour that is $0.96/hour, tied with the entire five-node fleet as the largest line on the bill.
- **Interface endpoints are billed per endpoint per Availability Zone.** Six services (`bedrock-runtime`, `bedrock-agent-runtime`, `kms`, `logs`, `secretsmanager`, `sts`) across three AZs is 18 billable endpoint-hours, not six. This keeps the sensitive plane off the NAT gateway, which is a deliberate design point of the workshop rather than an accident.

## Usage and one-time charges

| Item | Cost | Basis |
| --- | --- | --- |
| NAT data processing for container image pulls | $0.4500 | assumes ~10 GB pulled |
| Bedrock Nova Pro inference across the three use cases | $0.1280 | assumes ~40 agent calls |
| Audit pipeline: Firehose, CloudWatch Logs, S3, Athena, ECR | $0.0500 | ~2 hours of pod activity |
| Bedrock knowledge base ingest (Nova 2 embeddings) | $0.0007 | measured 21 KB corpus |
| **Usage subtotal** | **$0.6287** | |

The two assumptions above are the only estimated quantities on this page; everything else is measured or read from AWS list prices. Exploring the agents more than the walkthrough asks will push the inference number up, but Nova Pro is $0.0008 per 1K input tokens and $0.0032 per 1K output tokens — you would need thousands of extra calls to move the total by a dollar.

## What actually controls your bill

**Going faster barely helps.** Deploying the three tiers takes 40–60 minutes on its own — Tier 1 ~25–35 min, Tier 2 ~10–15 min, Tier 3 ~5–10 min — and none of that compresses. In a 90-minute window you are paying full rate for roughly 50 minutes of `terraform apply` and 40 minutes of hands-on work. Reading the pages quickly saves cents.

**Idle capacity is 88% of the bill.** Of the $5.41 a two-hour run costs, $4.78 is capacity that exists whether you touch it or not: five nodes, four OCUs, eighteen endpoints, an idle database. That is the nature of the stack, and it is why the only lever that matters is the next one.

**Tearing down promptly is the whole game.** Left running, the same stack costs about **$58 per day** and **$402 per week**. Forgetting it over a long weekend costs more than fifty workshop runs. When you finish, work through the **Cleanup** module — `teardown.sh` removes everything this page prices, and `teardown.sh --dry-run` shows you what it will destroy first.

## Provenance

Every unit price above was pulled from the AWS Price List API for `us-east-1` on **18 August 2026**, and every quantity from the Terraform state of a completed deployment. One number is neither: the node root volumes are shown at EKS's default of 20 GiB per node, because the workshop sets no explicit `disk_size` — at $0.011/hour it does not move the total.

AWS list prices change, and this page does not update itself. To re-derive the figures for your own region, or to model a longer run, use the [AWS Pricing Calculator](https://calculator.aws/). These are estimates and exclude any taxes, credits, Free Tier allowances or Savings Plans that apply to your account.
