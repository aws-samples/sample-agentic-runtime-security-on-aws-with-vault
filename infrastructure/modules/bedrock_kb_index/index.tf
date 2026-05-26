################################################################################
# bedrock_kb_index Module — AOSS vector index via CloudFormation.
#
# WHY CLOUDFORMATION (not the opensearch provider):
#   The opensearch-project/opensearch provider 2.2.0 does not share the
#   AWS provider's resolved credentials — its AWS SDK Go default chain
#   resolves separately, which can fail with NoCredentialProviders in
#   environments where ambient credentials are scoped. Pinning to a newer
#   opensearch provider is blocked by Pitfall B3 (later 2.x versions broke
#   AOSS sigv4 signing).
#
#   The simpler answer: create the index via
#   AWS::OpenSearchServerless::Index inside an aws_cloudformation_stack
#   resource, driven by the already-authenticated aws.main provider.
#   Single credential chain, no bridging required.
#
# Pitfalls preserved:
#   B2 — AOSS does NOT auto-create the index for KB; we declare it here.
#   B4 — Nova 2 Multimodal Embeddings dimension is 1024 (explicitly configured).
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

################################################################################
# Vector index for the Bedrock Knowledge Base.
#
#   Knn = true / KnnAlgoParamEfSearch = 512 — k-NN search tuning.
#   Dimension = 1024 — Nova 2 Multimodal Embeddings (Pitfall B4).
#   Method.Engine = faiss / SpaceType = l2 — Bedrock KB requirement.
#
# No depends_on on the AOSS collection — that's enforced cross-component
# via component.bedrock_kb_index.depends_on = [component.bedrock_kb_aoss]
# in infrastructure/components.tfcomponent.hcl.
#
# CFN deletion: do NOT set DeletionPolicy on the resource — default
# behavior is Delete, which removes the index when the stack is destroyed.
################################################################################
resource "aws_cloudformation_stack" "kb_index" {
  name = "${var.kb_name}-aoss-index"

  template_body = yamlencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "OpenSearch Serverless vector index for the Bedrock Knowledge Base (managed by Terraform)"

    Resources = {
      KnowledgeBaseIndex = {
        Type = "AWS::OpenSearchServerless::Index"
        Properties = {
          CollectionEndpoint = var.aoss_collection_endpoint
          IndexName          = "bedrock-knowledge-base-default-index"

          Settings = {
            Index = {
              Knn                  = true
              KnnAlgoParamEfSearch = 512
            }
          }

          Mappings = {
            Properties = {
              "bedrock-knowledge-base-default-vector" = {
                Type      = "knn_vector"
                Dimension = 1024 # Nova 2 Multimodal Embeddings; Pitfall B4.
                Method = {
                  Name      = "hnsw"
                  Engine    = "faiss"
                  SpaceType = "l2"
                  Parameters = {
                    M              = 16
                    EfConstruction = 512
                  }
                }
              }
              "AMAZON_BEDROCK_METADATA"   = { Type = "text", Index = false }
              "AMAZON_BEDROCK_TEXT_CHUNK" = { Type = "text", Index = true }
            }
          }
        }
      }
    }
  })

  tags = var.tags
}
