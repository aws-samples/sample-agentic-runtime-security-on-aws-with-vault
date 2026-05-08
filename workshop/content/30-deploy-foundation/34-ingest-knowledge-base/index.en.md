---
title: 'Ingest Knowledge Base'
weight: 34
---

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
