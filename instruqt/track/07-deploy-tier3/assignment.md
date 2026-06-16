---
slug: deploy-tier3
type: challenge
title: Deploy Tier 3 — Workloads
teaser: Use Case agent pods, banking app + UI, banking DB seed, Bedrock KB ingest.
tabs:
  - title: Terminal
    type: terminal
    hostname: shell
---

Tier 3 deploys the application workloads on top of tier-1 (cluster) and tier-2
(Vault + IVIA):

- **Use Case agents** — `uc1-agent`, `uc2-agent`, `uc3-agent` (Strands)
- **Banking app** — `banking-app` (Node.js API) + `banking-ui` (Carbon UI)
- **Audit substrate** — Fluent Bit Pod-Identity → Firehose → S3 → Athena

`deploy-workshop.sh --tier 3` runs steps 10-14 of the orchestrator:

10. `terraform apply` against `infrastructure/workloads/` (UC1 + UC2 + UC3 pods)
11. Post-tier-3 shared-ALB assertion + IVIA redirect reconcile
12. Verify OpenLDAP user `oscar` is seeded
13. **Seed the banking database** (`seed-banking-db.sh`) — transactions table
14. **Ingest the Bedrock KB corpus** (`sync-bedrock-kb.sh`) — HR + customers + finance

## Inspect what landed

```bash
kubectl get pods -n workshop
```

Expected: `uc1-agent`, `uc2-agent`, `uc3-agent`, `banking-app`, `banking-ui`
all `Running`.

```bash
kubectl get ingress -n workshop
```

Expected: a single shared ALB Ingress with `banking-app` and `banking-ui`
hostname rules. The ADDRESS column shows the ALB DNS name.

Confirm the banking DB was seeded:

```bash
cd /root/workshop
bash infrastructure/scripts/verify-uc1.sh   # also exercises the seeded data
```

Confirm the Bedrock KB ingestion job completed:

```bash
cd /root/workshop
KB_ID=$(terraform -chdir=infrastructure output -raw kb_id)
aws --region "$AWS_REGION_KB" bedrock-agent list-ingestion-jobs \
  --knowledge-base-id "$KB_ID" \
  --data-source-id "$(terraform -chdir=infrastructure output -raw kb_hr_data_source_id)" \
  --query 'ingestionJobSummaries[0].status' --output text
```

Expected: `COMPLETE`.
