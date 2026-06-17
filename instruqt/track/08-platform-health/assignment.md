---
slug: platform-health
type: challenge
title: Platform Health Check
teaser: One script verifies EKS, RDS, Bedrock KB, audit log groups, and the region contract.
tabs:
  - title: Terminal
    type: terminal
    hostname: cloud-client
---

Before walking the use cases, run the foundation verification script. It
confirms all modules deployed correctly and the audit substrate is in place.

```bash
cd /root/workshop
bash infrastructure/scripts/test-foundation.sh
```

That single command takes no arguments — it auto-derives everything from
`infrastructure/terraform.tfvars` and AWS: cluster name, Knowledge Base id,
DB instance id, region, and KB region.

When all checks pass, you will see:

```
===============================================================================
  Foundation verification: ALL components passed
===============================================================================
```

If any check fails, the script prints a red error with a `Fix:` remediation
hint. Fix the cause and re-run (the script is idempotent).

## What the script verifies

| Component        | What it checks                                                                                       |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| EKS              | cluster ACTIVE, >= 2 Ready nodes, 5 managed add-ons ACTIVE, workshop access entry present            |
| RDS              | instance available, PostgreSQL 17, Secrets Manager master password, storage encrypted, pgaudit loaded |
| Bedrock KB       | KB ACTIVE, AOSS collection ACTIVE, 3 data sources (HR/customers/finance) AVAILABLE, retrieval smoke   |
| Audit log groups | `/workshop/vault-audit`, `/workshop/ivia-decision`, `/workshop/agent-trace` exist + KMS-encrypted    |
| Region contract  | no `region = "..."` literal in `infrastructure/` outside `terraform.tfvars`                          |

When the script prints ALL PASSED, advance to Use Case 1.
