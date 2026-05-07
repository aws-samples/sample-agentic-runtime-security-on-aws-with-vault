################################################################################
# bedrock_kb_aoss Module — S3 corpus bucket + SSE-KMS + corpus upload.
#
# Bucket holds the synthetic workshop corpus (HR + customers + finance).
# 8 markdown files under sample_corpus/{hr,customers,finance}/ are uploaded
# via aws_s3_object for_each over fileset() so adding/removing corpus files
# is a Terraform-tracked operation.
################################################################################

resource "aws_s3_bucket" "kb_corpus" {
  bucket_prefix = "${var.kb_name}-corpus-"
  force_destroy = true # Workshop ephemeral; teardown deletes everything.
  tags          = var.tags
}

# SSE-KMS using workshop CMK (matches RDS storage + AOSS encryption context).
resource "aws_s3_bucket_server_side_encryption_configuration" "kb_corpus" {
  bucket = aws_s3_bucket.kb_corpus.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.workshop_cmk_arn
    }
    bucket_key_enabled = true
  }
}

# Block all public access — corpus stays private; KB role reads via IAM.
resource "aws_s3_bucket_public_access_block" "kb_corpus" {
  bucket = aws_s3_bucket.kb_corpus.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Corpus upload — fileset() over sample_corpus/**/*.md.
locals {
  corpus_files = fileset("${path.module}/sample_corpus", "**/*.md")
}

resource "aws_s3_object" "corpus" {
  for_each = toset(local.corpus_files)

  bucket = aws_s3_bucket.kb_corpus.id
  key    = each.value
  source = "${path.module}/sample_corpus/${each.value}"
  etag   = filemd5("${path.module}/sample_corpus/${each.value}")

  content_type = "text/markdown"
}
