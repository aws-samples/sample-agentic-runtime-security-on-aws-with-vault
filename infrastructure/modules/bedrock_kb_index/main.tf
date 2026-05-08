################################################################################
# bedrock_kb_index Module — Knowledge Base + 3 data sources.
#
# Sibling of bedrock_kb_aoss. Closes the six-resource dance from
# RESEARCH Pattern 4: items 8 + 9 (KB + data sources). Items 1-7 (3 AOSS
# policies, AOSS collection, IAM role + policies, time_sleep) live in
# bedrock_kb_aoss; item 6 (the AOSS vector index) lives in index.tf in
# THIS module, but is created via aws_cloudformation_stack rather than the
# opensearch provider — see the comment at the top of index.tf for why.
#
# field_mapping pins the index field names that match the
# AWS::OpenSearchServerless::Index resource declared in index.tf:
#   - vector_field   = "bedrock-knowledge-base-default-vector"
#   - text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
#   - metadata_field = "AMAZON_BEDROCK_METADATA"
################################################################################

resource "aws_bedrockagent_knowledge_base" "kb" {
  name     = var.kb_name
  role_arn = var.kb_role_arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = var.embedding_model_arn

      embedding_model_configuration {
        bedrock_embedding_model_configuration {
          dimensions      = 1024
          embedding_data_type = "FLOAT32"
        }
      }

      supplemental_data_storage_configuration {
        storage_location {
          type = "S3"
          s3_location {
            uri = "s3://${var.kb_multimodal_bucket_id}/"
          }
        }
      }
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = var.aoss_collection_arn
      vector_index_name = "bedrock-knowledge-base-default-index"

      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  tags = var.tags

  depends_on = [aws_cloudformation_stack.kb_index]
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
      bucket_arn         = var.kb_corpus_bucket_arn
      inclusion_prefixes = [each.value]
    }
  }
}
