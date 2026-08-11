---
title: 'Verify Infrastructure'
weight: 33
---

Run the foundation verification script to confirm all modules deployed correctly. It checks EKS cluster status + nodes + addons, RDS status + pgaudit + encryption, Bedrock KB + data sources + retrieval, audit log groups with KMS, and the region contract.

```bash
bash infrastructure/scripts/test-foundation.sh
```

That single command takes no arguments — it auto-derives everything from `infrastructure/terraform.tfvars` and AWS: cluster name (`cluster_name`), Knowledge Base id (the `workshop-kb` KB), DB instance ID (`${cluster_name}-pg`), region, and KB region.

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

**OpenLDAP (IVIA user registry)** — deployment Available in the `verify-access` namespace, and the `oscar` user exists (`cn=oscar,dc=ibm,dc=com`)

**Vault native surface** — Vault reports an Enterprise (`+ent`) build, and the Agent Registry responds with the `uc1-agent` registration resolvable by display-name

**Region contract** — no canonical region literal for your deploy region anywhere in `infrastructure/` outside `terraform.tfvars`

::::

The last two groups reach past Tier 1 into the Tier-2 identity substrate. At an event that is
useful confirmation: it means the Vault and IVIA layer provisioned during account setup is
sound, not just the VPC/EKS/RDS foundation.
