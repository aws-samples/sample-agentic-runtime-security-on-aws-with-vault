################################################################################
# bedrock_kb_index Module — OpenSearch Serverless vector index.
#
# Sibling of bedrock_kb_aoss. The opensearch provider is declared at Stack
# level (infrastructure/providers.tfcomponent.hcl) and configured with
# url = component.bedrock_kb_aoss.aoss_collection_endpoint. This module
# uses that provider via the component.bedrock_kb_index.providers wiring.
#
# Pitfalls preserved:
#   B2 — AOSS does NOT auto-create the index for KB; we declare it here.
#   B3 — opensearch-project/opensearch provider pinned EXACT = 2.2.0 at Stack level.
#   B4 — Titan Text Embeddings v2 dimension is 1024 (NOT 1536; v1 was 1536).
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    opensearch = {
      source  = "opensearch-project/opensearch"
      version = "= 2.2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

################################################################################
# Vector index for the Bedrock Knowledge Base.
#
#   dimension = 1024 — Titan Text Embeddings v2 (NOT 1536; Pitfall B4).
#   method.engine = faiss / space_type = l2 — Bedrock KB requirement.
#
# No depends_on on the AOSS collection — that's enforced cross-component
# via component.bedrock_kb_index.depends_on = [component.bedrock_kb_aoss]
# in infrastructure/components.tfcomponent.hcl.
################################################################################
resource "opensearch_index" "kb" {
  name                           = "bedrock-knowledge-base-default-index"
  number_of_shards               = "2"
  number_of_replicas             = "0"
  index_knn                      = true
  index_knn_algo_param_ef_search = "512"

  mappings = jsonencode({
    properties = {
      "bedrock-knowledge-base-default-vector" = {
        type      = "knn_vector"
        dimension = 1024 # Titan v2; Titan v1 was 1536 — Pitfall B4.
        method = {
          name       = "hnsw"
          engine     = "faiss"
          space_type = "l2"
          parameters = {
            m               = 16
            ef_construction = 512
          }
        }
      }
      "AMAZON_BEDROCK_METADATA"   = { type = "text", index = "false" }
      "AMAZON_BEDROCK_TEXT_CHUNK" = { type = "text", index = "true" }
    }
  })

  force_destroy = true
}
