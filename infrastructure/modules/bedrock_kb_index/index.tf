################################################################################
# bedrock_kb_index Module — AOSS vector index via CloudFormation.
#
# WHY CLOUDFORMATION (not the opensearch provider):
#   HCP Terraform Stacks authenticates the AWS provider via OIDC web
#   identity (assume_role_with_web_identity). The opensearch-project/
#   opensearch provider 2.2.0 does not expose the equivalent web-identity
#   block, and HCP Stacks has no mechanism to share the AWS provider's
#   resolved credentials with another provider. The opensearch provider's
#   AWS SDK Go default chain finds nothing on the runner — apply fails
#   with NoCredentialProviders. Pinning to a newer opensearch provider is
#   blocked by Pitfall B3 (later 2.x versions broke AOSS sigv4 signing).
#
#   The canonical Stacks-native answer (per HCP Stacks identity_token docs
#   + AWS CloudFormation reference): create the index via
#   AWS::OpenSearchServerless::Index inside an aws_cloudformation_stack
#   resource, driven by the already-OIDC-authenticated aws.main provider.
#   Same OIDC identity, no second credential chain to bridge.
#
# Pitfalls preserved:
#   B2 — AOSS does NOT auto-create the index for KB; we declare it here.
#   B4 — Titan Text Embeddings v2 dimension is 1024 (NOT 1536; v1 was 1536).
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
#   Dimension = 1024 — Titan Text Embeddings v2 (NOT 1536; Pitfall B4).
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
    Description              = "OpenSearch Serverless vector index for the Bedrock Knowledge Base (workshop-managed via HCP Terraform Stacks)"

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
                Dimension = 1024 # Titan v2; Titan v1 was 1536 — Pitfall B4.
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
