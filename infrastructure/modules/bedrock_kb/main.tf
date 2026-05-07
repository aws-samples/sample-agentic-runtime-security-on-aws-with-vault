################################################################################
# bedrock_kb Module — Knowledge Base + 3 data sources + IAM-propagation bridge.
#
# Closes the six-resource dance from RESEARCH Pattern 4:
#   7. time_sleep — IAM eventual-consistency bridge (Pitfall B1).
#   8. aws_bedrockagent_knowledge_base — depends_on opensearch_index AND time_sleep.
#   9. 3× aws_bedrockagent_data_source — one per domain (HR, customers, finance).
################################################################################

################################################################################
# Pitfall B1 — IAM eventual consistency.
#
# After the 4 inline role policies are attached, AWS IAM needs ~10-20s for the
# permission grants to propagate before bedrock.amazonaws.com can assume the
# role and exercise them. Without this sleep, aws_bedrockagent_knowledge_base
# fails on first apply with AccessDenied on the AOSS APIAccessAll grant.
################################################################################
resource "time_sleep" "kb_iam_propagate" {
  create_duration = "20s"

  depends_on = [
    aws_iam_role_policy.kb_aoss,
    aws_iam_role_policy.kb_s3,
    aws_iam_role_policy.kb_bedrock,
    aws_iam_role_policy.kb_kms,
  ]
}

################################################################################
# Bedrock Knowledge Base — VECTOR type backed by AOSS.
#
# field_mapping pins the index field names that match the opensearch_index
# resource declared in aoss.tf:
#   - vector_field   = "bedrock-knowledge-base-default-vector"
#   - text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
#   - metadata_field = "AMAZON_BEDROCK_METADATA"
#
# depends_on enforces that BOTH the index exists AND IAM has propagated
# before the KB resource attempts its initial validate-on-create call.
################################################################################
resource "aws_bedrockagent_knowledge_base" "kb" {
  name     = var.kb_name
  role_arn = aws_iam_role.bedrock_kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = data.aws_bedrock_foundation_model.embedding.model_arn
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = "bedrock-knowledge-base-default-index"

      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  tags = var.tags

  depends_on = [
    opensearch_index.kb,
    time_sleep.kb_iam_propagate,
  ]
}

################################################################################
# 3 S3 data sources — one per domain corpus prefix.
#
# inclusion_prefixes scopes each data source to its own subdirectory in the
# corpus bucket so an ingestion job for "hr-handbook" only re-indexes hr/*.md.
# This drives the UC1/UC2/UC3 retrieval stories in Phases 4-6.
################################################################################
locals {
  data_sources = {
    hr-handbook = "hr/"
    customers   = "customers/"
    finance     = "finance/"
  }
}

resource "aws_bedrockagent_data_source" "domain" {
  for_each = local.data_sources

  knowledge_base_id = aws_bedrockagent_knowledge_base.kb.id
  name              = each.key

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn         = aws_s3_bucket.kb_corpus.arn
      inclusion_prefixes = [each.value]
    }
  }
}
