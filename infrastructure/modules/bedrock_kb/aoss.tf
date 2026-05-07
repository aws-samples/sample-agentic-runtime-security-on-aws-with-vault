################################################################################
# bedrock_kb Module — OpenSearch Serverless (AOSS) collection + vector index
#
# RESEARCH Pattern 4 — "Bedrock KB on OpenSearch Serverless — Six-Resource Dance".
# Strict ordering enforced via depends_on:
#   1. 3 AOSS policies (encryption + network + data access)
#   2. AOSS VECTORSEARCH collection (depends_on the 3 policies)
#   3. opensearch_index (provider switch; depends_on collection)
#
# Pitfall B2 — AOSS does NOT auto-create the index for KB; we must create it.
# Pitfall B3 — opensearch-project/opensearch provider pinned EXACT = 2.2.0
#              (newer versions broken with AOSS auth as of 2026-05).
# Pitfall B4 — Titan Text Embeddings v2 dimension is 1024 (NOT 1536; v1 was 1536).
################################################################################

# Module-level required_providers — needed for `terraform validate` even though
# providers.tfcomponent.hcl pins these for the root component.
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

data "aws_caller_identity" "this" {}

################################################################################
# 1. AOSS encryption policy — workshop CMK (NOT AWS-owned key).
#    Matches RDS + log group encryption context per Phase 2 KMS reuse decision.
################################################################################
resource "aws_opensearchserverless_security_policy" "kb_encryption" {
  name = "${var.kb_name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [
      {
        Resource     = ["collection/${var.kb_collection_name}"]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = false
    KmsARN      = var.workshop_cmk_arn
  })
}

################################################################################
# 2. AOSS network policy — PUBLIC (CONTEXT decision; Pitfall A2).
#    No aoss interface endpoint required. Workshop default; private-VPC
#    variant would require an additional aws_vpc_endpoint of type "aoss".
################################################################################
resource "aws_opensearchserverless_security_policy" "kb_network" {
  name = "${var.kb_name}-net"
  type = "network"
  policy = jsonencode([
    {
      Rules = [
        { ResourceType = "collection", Resource = ["collection/${var.kb_collection_name}"] },
        { ResourceType = "dashboard", Resource = ["collection/${var.kb_collection_name}"] }
      ]
      AllowFromPublic = true
    }
  ])
}

################################################################################
# 3. AOSS data access policy — KB role + caller identity.
#    Caller identity is needed so the Terraform-applying principal can create
#    the opensearch_index via the opensearch provider during apply.
################################################################################
resource "aws_opensearchserverless_access_policy" "kb_data" {
  name = "${var.kb_name}-data"
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "index"
          Resource     = ["index/${var.kb_collection_name}/*"]
          Permission   = ["aoss:*"]
        },
        {
          ResourceType = "collection"
          Resource     = ["collection/${var.kb_collection_name}"]
          Permission   = ["aoss:*"]
        }
      ]
      Principal = [
        aws_iam_role.bedrock_kb.arn,
        data.aws_caller_identity.this.arn
      ]
    }
  ])
}

################################################################################
# 4. AOSS VECTORSEARCH collection — depends on all 3 policies.
################################################################################
resource "aws_opensearchserverless_collection" "kb" {
  name = var.kb_collection_name
  type = "VECTORSEARCH"

  tags = var.tags

  depends_on = [
    aws_opensearchserverless_access_policy.kb_data,
    aws_opensearchserverless_security_policy.kb_encryption,
    aws_opensearchserverless_security_policy.kb_network
  ]
}

################################################################################
# 5. opensearch provider configuration is intentionally NOT declared here.
#
# Stacks rejects inline `provider "opensearch" {}` blocks inside component
# modules ("Inline provider configuration not allowed"). The opensearch
# provider is configured at the Stack level in
# infrastructure/providers.tfcomponent.hcl as `provider "opensearch" "main"`,
# wired to component.bedrock_kb.aoss_collection_endpoint, and passed to this
# component via `providers = { opensearch = provider.opensearch.main }` in
# infrastructure/components.tfcomponent.hcl.
#
# Pitfall B3: provider version pinned EXACT = 2.2.0 at the Stack level.
################################################################################

################################################################################
# 6. Vector index for the Bedrock Knowledge Base.
#    AOSS does NOT auto-create the index; we declare it explicitly (Pitfall B2).
#
#    dimension = 1024 — Titan Text Embeddings v2 (NOT 1536; Pitfall B4).
#    method.engine = faiss / space_type = l2 — Bedrock KB requirement.
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

  depends_on = [aws_opensearchserverless_collection.kb]
}
