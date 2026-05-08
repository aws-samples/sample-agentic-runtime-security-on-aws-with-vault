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

# Use `content = file(...)` instead of `source = "..."` because HCP Stacks
# runs plan and apply in different working directories
# (stack_plan/jobNNN/... vs stack_apply/jobMMM/...). With `source`, the
# AWS provider's "consistent final plan" check fails because the absolute
# path differs between phases — even though the file content is identical.
# `content = file(...)` reads the file at plan time and stores the content
# as a known value, so the apply phase sees the same value.
# Trade-off: full file content goes through state. Acceptable here — corpus
# files are small synthetic markdown (under 5 KB each).
resource "aws_s3_object" "corpus" {
  for_each = toset(local.corpus_files)

  bucket       = aws_s3_bucket.kb_corpus.id
  key          = each.value
  content      = file("${path.module}/sample_corpus/${each.value}")
  content_type = "text/markdown"

  # source_hash (NOT etag) is the AWS provider's content-tracking attribute
  # that works with SSE-KMS. For SSE-KMS objects S3 returns an opaque
  # server-computed ETag (not the plaintext MD5), so an `etag = filemd5(...)`
  # comparison perpetually drifts on this bucket — see stack run
  # sdr-m4miM2QRJasVkSiF (2026-05-08) where 2 of 8 corpus objects looped
  # because they got re-uploaded after the bucket flipped from AES256 to
  # SSE-KMS mid-deploy. source_hash is local-only state, no S3 comparison.
  source_hash = filemd5("${path.module}/sample_corpus/${each.value}")
}
