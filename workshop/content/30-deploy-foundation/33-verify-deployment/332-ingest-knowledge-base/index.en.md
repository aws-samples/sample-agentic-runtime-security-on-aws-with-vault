---
title: 'Ingest Knowledge Base'
weight: 332
---

:::alert{header="Already run by deploy-workshop.sh" type="info"}
Step 14 of `deploy-workshop.sh` (`sync-bedrock-kb.sh`) already triggered this ingestion during the deploy. This page lets you confirm it completed — and re-trigger it if needed. Starting a fresh ingestion job is idempotent: it re-embeds the same corpus and converges.
:::

The `aws_bedrockagent_data_source` resources create the binding between the KB and the S3 corpus, but they do **not** run the ingestion. Your **Knowledge Base ID** is printed at the end of the previous step ([Verify Infrastructure](../331-verify-infrastructure/)) in the **Next step — Ingest Knowledge Base** box — or resolve it directly with the first command below. Then trigger one ingestion job per data source:

```bash
# KB ID — shown at the end of the previous step, or resolve it directly here:
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 \
  --query 'knowledgeBaseSummaries[?name==`workshop-kb`].knowledgeBaseId | [0]' --output text)
echo "KB_ID=$KB_ID"

for DS in $(aws bedrock-agent list-data-sources \
              --knowledge-base-id "$KB_ID" \
              --region us-east-1 \
              --query 'dataSourceSummaries[].dataSourceId' \
              --output text); do
  aws bedrock-agent start-ingestion-job \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS" \
    --region us-east-1
done
```

Wait ~5 minutes, then confirm each ingestion job completed:

```bash
for DS in $(aws bedrock-agent list-data-sources \
              --knowledge-base-id "$KB_ID" \
              --region us-east-1 \
              --query 'dataSourceSummaries[].dataSourceId' \
              --output text); do
  echo "=== Data source $DS ==="
  aws bedrock-agent list-ingestion-jobs \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS" \
    --region us-east-1 \
    --query 'sort_by(ingestionJobSummaries, &startedAt)[-1].[status,startedAt]' \
    --output text
done
```

`sort_by(...)[-1]` matters here: `list-ingestion-jobs` does **not** return newest-first, so plain `[0]` can hand you a job from a previous run. On a page whose whole point is "re-trigger, then confirm", that would show you a stale `COMPLETE` while the sync you just started is still running.

**Expected output:** every line shows `COMPLETE` with a timestamp from the sync you just started. If any data source returns `FAILED`, check that the corpus S3 objects uploaded successfully (`aws s3 ls s3://<corpus-bucket>/`) and the KB role has `s3:GetObject` on the bucket.
