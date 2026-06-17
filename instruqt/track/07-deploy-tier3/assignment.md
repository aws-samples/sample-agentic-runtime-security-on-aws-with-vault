---
slug: deploy-tier3
id: njr2t4hovkvq
type: challenge
title: Deploy Tier 3 — Workloads
teaser: Use Case agent pods, banking app + UI, banking DB seed, Bedrock KB ingest.
tabs:
- id: ffysxwsvfpqq
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
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

## Run the deploy

```bash
cd /root/workshop
bash infrastructure/scripts/deploy-workshop.sh --tier 3
```

The preflight values from tier 1 are cached and reused — no re-prompt.

## Inspect what landed

The tier-3 workloads split across two namespaces:

- `uc1` — `uc1-agent` (UC1 Strands agent)
- `banking-app` — `banking-ui`, `banking-agent`, `banking-mcp-server`, `uc3-agent`

```bash
kubectl get pods -n uc1
kubectl get pods -n banking-app
```

Expected: all deployments `Running`.

```bash
kubectl get ingress -A
```

Expected: a `banking-ui-ingress` in the `banking-app` namespace with the ALB
DNS name populated under ADDRESS.

Confirm the banking DB was seeded:

```bash
cd /root/workshop
bash infrastructure/scripts/verify-uc1.sh   # also exercises the seeded data
```

Confirm the Bedrock KB ingestion job completed:

```bash
cd /root/workshop
KB_ID=$(terraform -chdir=infrastructure output -raw kb_id)
DS_ID=$(aws --region "$AWS_REGION_KB" bedrock-agent list-data-sources \
  --knowledge-base-id "$KB_ID" \
  --query 'dataSourceSummaries[0].dataSourceId' --output text)
aws --region "$AWS_REGION_KB" bedrock-agent list-ingestion-jobs \
  --knowledge-base-id "$KB_ID" \
  --data-source-id "$DS_ID" \
  --query 'ingestionJobSummaries[0].status' --output text
```

Expected: `COMPLETE`.
