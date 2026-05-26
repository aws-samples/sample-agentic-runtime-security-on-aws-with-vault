---
title: 'Deploy Foundation'
weight: 30
---

In this module you run the single `terraform apply` that provisions the entire workshop stack — VPC, EKS cluster, RDS PostgreSQL, Bedrock Knowledge Base, the audit-correlation substrate, and the in-cluster platform backbone (**HashiCorp Vault** + **IBM Verify Identity Access**). The later Platform and Use Case modules verify and configure what this apply deploys; they do not run their own `terraform apply`. Work through the sub-modules in the left navigation in order.

## Pre-flight check

Confirm you completed the [Prerequisites module](../20-prerequisites/) before deploying:

```bash
bash infrastructure/scripts/check-prerequisites.sh
```

If any item fails, return to Prerequisites — this deploy will fail at apply time without all three (AWS access, IVIA licenses, Bedrock model access).

## The audit-correlation contract

Before any workload lands on this cluster, the workshop pays its **audit-correlation design tax**:

- **One workshop CMK** (`alias/workshop-data`) that encrypts RDS storage, OpenSearch Serverless data, the S3 corpus bucket, and every CloudWatch log group — one key, one encryption-context story.
- **Three pre-created CloudWatch log groups** that fluent-bit DaemonSets ship into by ARN: `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace`.
- **A Glue catalog database** (`workshop_logs`) and **Athena workgroup** (`workshop`) that the Use Case 3 audit-correlation query runs against.

:::alert{header="Why this matters now" type="info"}
Trying to retrofit cross-plane audit correlation after agents and Vault are running is effectively impossible — every plane stamps a different correlation field, log groups inherit the wrong KMS key, and the JOIN never resolves. This module deliberately fronts the cost before anyone writes agent code.
:::
