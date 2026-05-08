################################################################################
# bedrock_kb_aoss Module — OpenSearch Serverless (AOSS) collection + 3 policies.
#
# Sibling of bedrock_kb_index. The split exists because the opensearch provider
# at the Stack level is configured with `url = component.bedrock_kb_aoss.aoss_collection_endpoint`
# and bedrock_kb_index uses that provider — placing both in the same component
# would create a `provider → component → provider` cycle that Stacks rejects.
#
# This module owns the AOSS collection, its 3 policies, the IAM role consumed
# by Bedrock KB, the S3 corpus bucket, and the time_sleep that gates IAM
# propagation. It does NOT use the opensearch provider.
#
# Pitfalls preserved:
#   B1 — IAM eventual consistency (time_sleep in main.tf).
#   B2 — AOSS does NOT auto-create the index; bedrock_kb_index handles it.
#   B3 — opensearch-project/opensearch provider pinned EXACT = 2.2.0 at Stack level.
#   B4 — Nova 2 Embeddings dimension is 1024 (handled in bedrock_kb_index/index.tf).
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

data "aws_caller_identity" "this" {}

# data.aws_caller_identity.this.arn returns the assumed-role STS ARN at
# apply time (e.g. arn:aws:sts::ACCOUNT:assumed-role/hcp-stacks-deploy/SESSION).
# AOSS data-access policies match Principal against the underlying IAM role
# ARN, NOT the STS session ARN. Use aws_iam_session_context to resolve the
# session back to the role ARN that issued it.
#
# Without this resolution, CloudFormation's AWS::OpenSearchServerless::Index
# handler (in modules/bedrock_kb_index/index.tf) calls AOSS CreateIndex under
# the deploy role, AOSS evaluates the data-access policy, doesn't see the role
# in the Principal list, and returns AccessDenied.
data "aws_iam_session_context" "this" {
  arn = data.aws_caller_identity.this.arn
}

################################################################################
# KMS CMK for KB resources (AOSS encryption + S3 SSE).
# Separate from the audit module's CMK because KMS keys are regional — KB
# components live in us-east-1 while audit lives in us-west-2.
################################################################################
resource "aws_kms_key" "kb" {
  description         = "KB CMK (AOSS + S3 corpus/multimodal encryption)"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_kms_alias" "kb" {
  name          = "alias/${var.kb_name}-data"
  target_key_id = aws_kms_key.kb.key_id
}

################################################################################
# 1. AOSS encryption policy — KB CMK.
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
    KmsARN      = aws_kms_key.kb.arn
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
#    Caller identity is the Stacks runner principal — needed so bedrock_kb_index
#    (a separate component) can create the opensearch_index using the same
#    runner identity at apply time.
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
        data.aws_iam_session_context.this.issuer_arn,
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
