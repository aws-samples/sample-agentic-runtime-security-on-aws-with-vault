---
title: 'Deploy Foundation'
weight: 30
---

In this module you deploy the entire AWS foundation via `terraform apply` — VPC, EKS cluster, RDS PostgreSQL, Bedrock Knowledge Base, and the audit-correlation substrate. Work through the sub-modules in the left navigation in order.

## Reference architecture

![Reference architecture](/static/images/architecture-overview.svg)

The eleven Terraform modules wire together in dependency order. Three (`audit`, `vpc`, `bedrock_kb_aoss`) have no inter-module dependencies — they apply in parallel. The others layer on top: `eks` depends on `vpc` + `audit`; `rds` depends on `vpc` + `audit` + `eks`; `bedrock_kb_index` depends on `bedrock_kb_aoss`; `addons` depends on `eks`.

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
