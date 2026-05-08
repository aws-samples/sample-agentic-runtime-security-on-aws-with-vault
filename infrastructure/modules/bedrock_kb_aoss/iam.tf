################################################################################
# bedrock_kb_aoss Module — IAM role + 4 inline policies for the Bedrock KB.
#
# The KB service role is assumed by bedrock.amazonaws.com and grants:
#   - aoss:APIAccessAll on the AOSS collection
#   - s3:GetObject + s3:ListBucket on the corpus bucket
#   - bedrock:InvokeModel on Nova 2 Multimodal Embeddings (direct, us-east-1 only)
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

# Pre-policy IAM propagation barrier — without this, the four
# aws_iam_role_policy resources below race the role's AWS-IAM propagation and
# fail with `NoSuchEntity: The role with name <kb_name>-role cannot be found`
# (run sdr-rgxc91GbDFEWcBcr, 2026-05-07). Distinct from the post-policy
# time_sleep.kb_iam_propagate in main.tf, which gates downstream KB creation
# on policy propagation — that one runs AFTER PutRolePolicy and so can't
# prevent NoSuchEntity. Codex confirmed both sleeps are needed.
resource "time_sleep" "wait_for_kb_role_propagation" {
  depends_on      = [aws_iam_role.bedrock_kb]
  create_duration = "20s"
}

# 1/4 — AOSS API access for the KB role.
resource "aws_iam_role_policy" "kb_aoss" {
  depends_on = [time_sleep.wait_for_kb_role_propagation]
  name       = "${var.kb_name}-aoss"
  role       = aws_iam_role.bedrock_kb.id

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

# 2/5 — S3 access on corpus bucket (read) + multimodal bucket (read/write).
resource "aws_iam_role_policy" "kb_s3" {
  depends_on = [time_sleep.wait_for_kb_role_propagation]
  name       = "${var.kb_name}-s3"
  role       = aws_iam_role.bedrock_kb.id

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
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.kb_multimodal.arn,
          "${aws_s3_bucket.kb_multimodal.arn}/*"
        ]
      }
    ]
  })
}

# Embedding model — Amazon Nova 2 Multimodal Embeddings (us-east-1 only).
# ARN constructed from var.region to avoid a data source API call that would
# fail in regions where the model isn't available (e.g. us-west-2 during
# Stacks destroy-plan for region migration).
locals {
  embedding_model_id  = "amazon.nova-2-multimodal-embeddings-v1:0"
  embedding_model_arn = "arn:aws:bedrock:${var.region}::foundation-model/${local.embedding_model_id}"
}

# 3/5 — Bedrock InvokeModel on the embedding model.
resource "aws_iam_role_policy" "kb_bedrock" {
  depends_on = [time_sleep.wait_for_kb_role_propagation]
  name       = "${var.kb_name}-bedrock"
  role       = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = local.embedding_model_arn
      }
    ]
  })
}

# 4/4 — KMS access on the workshop CMK (used for AOSS encryption + S3 SSE).
resource "aws_iam_role_policy" "kb_kms" {
  depends_on = [time_sleep.wait_for_kb_role_propagation]
  name       = "${var.kb_name}-kms"
  role       = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.kb.arn
      }
    ]
  })
}
