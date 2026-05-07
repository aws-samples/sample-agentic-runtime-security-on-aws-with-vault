# bedrock_kb

Phase 2 Stacks component implementing **INFR-04**: Bedrock Knowledge Base on
OpenSearch Serverless with seeded synthetic corpus driving UC1, UC2, UC3.

## Overview

Wraps **primitive** AWS resources for a Bedrock Knowledge Base (KB) on
OpenSearch Serverless (AOSS) instead of `aws-ia/terraform-aws-bedrock`. The
reason is pedagogical: the workshop teaches *what* the KB is made of, which
is impossible if the configuration is hidden behind a wrapper.

Declares 6 interlocking resources with strict ordering, plus a corpus bucket
and 8 synthetic markdown files:

1. 3 AOSS policies (encryption, network, data access)
2. AOSS VECTORSEARCH collection
3. opensearch_index (provider switch to `opensearch-project/opensearch = 2.2.0`)
4. IAM service role + 4 inline role policies (aoss, s3, bedrock, kms)
5. `time_sleep` 20s — IAM eventual-consistency bridge
6. `aws_bedrockagent_knowledge_base`
7. 3× `aws_bedrockagent_data_source` (one per domain)
8. S3 bucket + SSE-KMS + 8 `aws_s3_object` uploads (parallel track)

Highest-risk surface in Phase 2. Read **Pitfalls** before modifying.

## Decisions (locked from CONTEXT)

- **Multi-domain synthetic corpus** — HR + customers + finance, 8 files in
  `sample_corpus/{hr,customers,finance}/`. HR drives UC1 (non-personalized);
  customers drives UC2 (JWT-scoped); finance drives UC3 (privileged-action).
- **All synthetic, no real PII** — every file ends with the disclaimer footer
  `*Synthetic workshop content; not from any real company.*`. Email addresses
  use the `example.invalid` TLD (RFC 6761).
- **AOSS network policy: PUBLIC** — no AOSS interface VPC endpoint required.
  Private-VPC variant would add an `aws_vpc_endpoint` of type `aoss`.
- **Vector backend: OpenSearch Serverless 2 OCU minimum** — ~$345/mo;
  cost-noted in `workshop/content/20-prerequisites/`.
- **Embedding model: `amazon.titan-embed-text-v2:0`** — dimension 1024, NOT
  1536. Resolved via `data.aws_bedrock_foundation_model`.
- **Encryption: workshop CMK** — `alias/workshop-data` from the audit module;
  reused for AOSS encryption and S3 SSE-KMS, matching the RDS + log group
  pattern.

## Pitfalls — MUST READ before modifying

These are the four named pitfalls that bite reproducibly when standing up a
Bedrock KB on AOSS via Terraform. The numbering matches RESEARCH Pattern 4.

### B1 — IAM eventual consistency

After the 4 inline role policies attach, AWS IAM needs ~10-20s for grants to
propagate before `bedrock.amazonaws.com` can exercise them. Without the
`time_sleep.kb_iam_propagate` 20s bridge in `main.tf`,
`aws_bedrockagent_knowledge_base.kb` fails on first apply with `AccessDenied`.
Removing it will break first-apply.

### B2 — Index not created

AOSS does **not** auto-create the vector index for the KB. The Bedrock
console hides this by creating the index when you build the KB through the
UI; in Terraform you must create it explicitly. `opensearch_index.kb` in
`aoss.tf` is the reason this module needs the `opensearch-project/opensearch`
provider alongside `hashicorp/aws`.

### B3 — Provider pin must be exact `= 2.2.0`

`opensearch-project/opensearch` versions greater than 2.2.0 have a regression
breaking AWS request signing against AOSS auth. Pin **exactly** `= 2.2.0`
here and in the root `providers.tfcomponent.hcl`. Do not relax to `~> 2.2`.

### B4 — Titan v2 dimension is 1024

`amazon.titan-embed-text-v2:0` produces 1024-dim embeddings; v1 was 1536.
`opensearch_index.kb` in `aoss.tf` hard-codes `dimension = 1024` with a
comment. Switching embedding model requires updating both the data lookup
and the index dimension; mismatched dimensions cause silent query failures.

## Inputs

| Variable             | Type          | Default          | Description                                                |
| -------------------- | ------------- | ---------------- | ---------------------------------------------------------- |
| `region`             | `string`      | (required)       | AWS region. Threads through opensearch provider config.    |
| `kb_name`            | `string`      | `"workshop-kb"`  | Bedrock KB name and AOSS policy name prefix.               |
| `kb_collection_name` | `string`      | `"workshop-kb"`  | AOSS collection name.                                      |
| `workshop_cmk_arn`   | `string`      | (required)       | Workshop CMK ARN from `module.audit`.                      |
| `tags`               | `map(string)` | `{}`             | Tags applied to all taggable resources.                    |

## Outputs

| Output                    | Description                                          |
| ------------------------- | ---------------------------------------------------- |
| `knowledge_base_id`       | KB ID. Phase 4-6 agents use this for retrieval.      |
| `knowledge_base_arn`      | KB ARN. For agent IAM scoping.                       |
| `kb_role_arn`             | KB service role ARN.                                 |
| `kb_corpus_bucket`        | S3 bucket name holding the corpus.                   |
| `data_source_ids`         | Map domain → data source ID (3 entries).             |
| `aoss_collection_endpoint`| AOSS collection endpoint URL.                        |
| `aoss_collection_arn`     | AOSS collection ARN.                                 |

## Apply Order

1. AOSS encryption + network + data access policies (parallel).
2. AOSS VECTORSEARCH collection (`depends_on` the 3 policies).
3. `opensearch_index` (provider switch; `depends_on` collection).
4. IAM role + 4 inline role policies (aoss, s3, bedrock, kms).
5. `time_sleep` 20s (`depends_on` all 4 role policies — Pitfall B1).
6. `aws_bedrockagent_knowledge_base` (`depends_on` index AND time_sleep).
7. 3× `aws_bedrockagent_data_source` (depends on KB).

Concurrent track: S3 bucket + SSE-KMS + public-access-block + 8×
`aws_s3_object` uploads via `for_each` over `fileset()`.

## Sample Corpus Structure

| Domain      | Files                                                                  | Drives |
| ----------- | ---------------------------------------------------------------------- | ------ |
| `hr/`       | `employee-handbook.md`, `benefits-overview.md`, `pto-policy.md`        | UC1    |
| `customers/`| `customer-records.md`, `account-tiers.md`                              | UC2    |
| `finance/`  | `expense-policy.md`, `refund-procedures.md`, `approval-thresholds.md`  | UC3    |

Every file ends with the disclaimer: `*Synthetic workshop content; not from
any real company.*` Customer email addresses use the `example.invalid` TLD
reserved by RFC 6761.

## Component Wiring

```hcl
component "bedrock_kb" {
  source = "./modules/bedrock_kb"

  inputs = {
    region           = var.region
    workshop_cmk_arn = component.audit.workshop_cmk_arn
    tags             = var.tags
  }

  providers = {
    aws        = provider.aws.this
    opensearch = provider.opensearch.this
    time       = provider.time.this
  }
}
```

`bedrock_kb` has **no `depends_on` on `vpc`** — AOSS is public per the network
policy decision. The only inter-component dependency is on `audit` for the
workshop CMK ARN.

## Validation After Apply

After `terraform apply`, trigger a corpus ingestion job on each data source
(the data source resource creates the binding but does not run the ingestion):

```bash
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id <KB_ID> \
  --data-source-id <DS_ID> \
  --region <REGION>
```

Capture `<KB_ID>` from `terraform output -raw knowledge_base_id` and the three
`<DS_ID>` values from `terraform output -json data_source_ids`. The workshop
content for Phase 4 walks attendees through this exact flow.

## References

- RESEARCH Pattern 4 — "Bedrock KB on OpenSearch Serverless — Six-Resource
  Dance" in `.planning/phases/02-foundation-infrastructure/02-RESEARCH.md`.
- Terraform AWS provider — [`aws_bedrockagent_knowledge_base`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagent_knowledge_base).
- Terraform AWS provider — [`aws_opensearchserverless_collection`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/opensearchserverless_collection).
- Terraform OpenSearch provider — [`opensearch-project/opensearch`](https://registry.terraform.io/providers/opensearch-project/opensearch/2.2.0)
  pinned EXACT to `= 2.2.0`.
- Audit module README — describes the workshop CMK consumed here.
