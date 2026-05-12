---
title: 'Verify Infrastructure'
weight: 33
---

Run the foundation verification script to confirm all modules deployed correctly. It checks EKS cluster status + nodes + addons, RDS status + pgaudit + encryption, Bedrock KB + data sources + retrieval, audit log groups with KMS, and the region contract.

Get the two required values — `cluster_name` from `terraform.tfvars`, `knowledge_base_id` from the AWS CLI:

```bash
grep 'cluster_name' infrastructure/terraform.tfvars
```

```bash
aws bedrock-agent list-knowledge-bases \
  --region us-east-1 \
  --query 'knowledgeBaseSummaries[?name==`workshop-kb`].knowledgeBaseId' \
  --output text
```

Then run the verification:

```bash
bash infrastructure/scripts/test-foundation.sh \
  --cluster-name <CLUSTER_NAME> \
  --knowledge-base-id <KB_ID>
```

The script auto-derives everything else — DB instance ID (`${cluster_name}-pg`), region and KB region from `infrastructure/terraform.tfvars`.

When all checks pass, you will see:

```
===============================================================================
  Foundation verification: ALL components passed
===============================================================================
```

If any check fails, the script prints a red error with a `Fix:` remediation hint for each failure. Fix the issue and re-run — the script is idempotent.

::::expand{header="What the script verifies (click to expand)"}

**EKS** — cluster ACTIVE, >= 2 Ready nodes, 5 managed addons ACTIVE, access entry present

**RDS** — instance available, PostgreSQL 17, Secrets Manager master password, storage encrypted, pgaudit loaded

**Bedrock KB** — KB ACTIVE, AOSS collection ACTIVE, 3 data sources (HR/customers/finance) AVAILABLE, retrieval smoke query per data source

**Audit log groups** — `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace` exist and are KMS-encrypted with the workshop CMK

**Region contract** — no canonical region literal (e.g. `us-west-2`) anywhere in `infrastructure/` outside `terraform.tfvars`

::::
