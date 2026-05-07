################################################################################
# bedrock_kb_aoss Module — IAM role + 4 inline policies for the Bedrock KB.
#
# The KB service role is assumed by bedrock.amazonaws.com and grants:
#   - aoss:APIAccessAll on the AOSS collection
#   - s3:GetObject + s3:ListBucket on the corpus bucket
#   - bedrock:InvokeModel on the Titan Text Embeddings v2 foundation model
#   - kms:Decrypt + kms:GenerateDataKey + kms:DescribeKey on workshop CMK
#
# The role + policies live here (not in bedrock_kb_index) because the data
# access policy in aoss.tf grants this role direct AOSS permissions and the
# IAM grants need to propagate (time_sleep in main.tf) before bedrock_kb_index
# creates the KB.
################################################################################

data "aws_iam_policy_document" "kb_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bedrock_kb" {
  name               = "${var.kb_name}-role"
  assume_role_policy = data.aws_iam_policy_document.kb_assume.json
  tags               = var.tags
}

# 1/4 — AOSS API access for the KB role.
resource "aws_iam_role_policy" "kb_aoss" {
  name = "${var.kb_name}-aoss"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = aws_opensearchserverless_collection.kb.arn
      }
    ]
  })
}

# 2/4 — S3 read access on the corpus bucket.
resource "aws_iam_role_policy" "kb_s3" {
  name = "${var.kb_name}-s3"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.kb_corpus.arn,
          "${aws_s3_bucket.kb_corpus.arn}/*"
        ]
      }
    ]
  })
}

# Embedding model lookup — Titan Text Embeddings v2 (1024-dim).
data "aws_bedrock_foundation_model" "embedding" {
  model_id = "amazon.titan-embed-text-v2:0"
}

# 3/4 — Bedrock InvokeModel on the embedding model.
resource "aws_iam_role_policy" "kb_bedrock" {
  name = "${var.kb_name}-bedrock"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = data.aws_bedrock_foundation_model.embedding.model_arn
      }
    ]
  })
}

# 4/4 — KMS access on the workshop CMK (used for AOSS encryption + S3 SSE).
resource "aws_iam_role_policy" "kb_kms" {
  name = "${var.kb_name}-kms"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = var.workshop_cmk_arn
      }
    ]
  })
}
