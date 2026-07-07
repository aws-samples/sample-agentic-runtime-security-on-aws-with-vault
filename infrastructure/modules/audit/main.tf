################################################################################
# Audit Module — Foundation for cross-plane audit correlation
#
# Ships the LOAD-BEARING Phase 2 foundation that every downstream phase consumes:
#   1. Workshop CMK (alias/workshop-data) reused across RDS + AOSS + S3 + CloudWatch
#      — Pattern 6 (RESEARCH.md): one key, key policy expanded for each consumer.
#   2. Three pre-created CloudWatch log groups:
#        /workshop/vault-audit    — HashiCorp Vault audit device
#        /workshop/ivia-decision  — IBM Verify Identity Access decision logs
#        /workshop/agent-trace    — Strands agent OTel traces
#      — Pattern 7 (RESEARCH.md): per-source groups, NOT unified, KMS-encrypted.
#   3. Glue catalog database 'workshop_logs' + Athena workgroup 'workshop'
#      — Schema empty in Phase 2; Phase 6 adds tables (Open Question 4).
#   4. S3 bucket for Athena query results (workshop CMK SSE).
#
# The W3C traceparent audit-correlation contract (THE Phase 2 deliverable) is
# documented in infrastructure/docs/audit-correlation-queries.md — Phase 3
# (fluent-bit) and Phase 6 (Glue tables + UC3 cross-plane query) consume it.
#
# Reference: RESEARCH.md "Workshop CMK key policy snippet" + Patterns 6-7.
################################################################################

data "aws_caller_identity" "this" {}

#-------------------------------------------------------------------------------
# Workshop CMK — multi-service key policy
# Reused for RDS storage, AOSS encryption policy, S3 corpus SSE, CloudWatch logs.
#-------------------------------------------------------------------------------

data "aws_iam_policy_document" "workshop_cmk" {
  # Root account stmt — required for KMS to allow IAM-policy-based access.
  statement {
    sid       = "RootAccount"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.this.account_id}:root"]
    }
  }

  # RDS service stmt — RDS storage encryption uses this key on instance create.
  statement {
    sid = "AllowRDS"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }

  # CloudWatch Logs service stmt — region-derived service principal interpolates
  # var.region (Pitfall T1: never hardcode region). Encryption-context condition
  # constrains use to /workshop/* log groups (defense-in-depth).
  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    # CW Logs encryption-context covers the workshop log groups (vault-audit,
    # ivia-decision, agent-trace) AND the RDS-managed log group at
    # /aws/rds/instance/<id>/postgresql, which the rds module creates with
    # this CMK. Without the rds entry the RDS log group encryption fails on
    # first apply (Pitfall R3 mitigation).
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values = [
        "arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:log-group:/workshop/*",
        "arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:log-group:/aws/rds/instance/*",
      ]
    }
  }

  # AOSS + Bedrock service stmt — AOSS encryption policy + S3 corpus + KB ingestion.
  statement {
    sid = "AllowAOSSAndBedrock"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["aoss.amazonaws.com", "bedrock.amazonaws.com"]
    }
  }

  # Attendee crypto access (WSParticipantRole on a WS event / the self-paced
  # user's own identity). None of the attendee's managed policies grant
  # kms:Decrypt/GenerateDataKey, and the CMK's RootAccount stmt only DELEGATES to
  # IAM — so the attendee cannot use the CMK without a direct key-policy grant.
  # This statement grants exactly the crypto ops the attendee needs INDIRECTLY:
  #   - via Secrets Manager: reading the RDS-managed master secret (CMK-encrypted)
  #     in vault-configure (Step 8), seed-banking-db (Step 13), UC2 page 65.
  #   - via S3: UC2/UC3 Athena audit queries decrypt the CMK-SSE Firehose log
  #     bucket (kms:Decrypt) and write CMK-SSE query results (kms:GenerateDataKey).
  # Principal:* scoped by kms:ViaService + kms:CallerAccount is a DIRECT grant
  # (mirrors how aws/secretsmanager + aws/s3 default keys authorize account
  # principals), so it needs no attendee IAM change and no named-principal
  # plumbing. ViaService keeps raw KMS denied; CallerAccount blocks cross-account.
  statement {
    sid = "AllowAttendeeViaSecretsManagerAndS3"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "secretsmanager.${var.region}.amazonaws.com",
        "s3.${var.region}.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.this.account_id]
    }
  }
}

resource "aws_kms_key" "workshop" {
  description             = "Workshop CMK reused for RDS storage, AOSS encryption, S3 corpus SSE, and /workshop/* CloudWatch log groups (Pattern 6)."
  policy                  = data.aws_iam_policy_document.workshop_cmk.json
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = var.tags
}

resource "aws_kms_alias" "workshop" {
  name          = "alias/workshop-data"
  target_key_id = aws_kms_key.workshop.key_id
}

#-------------------------------------------------------------------------------
# CloudWatch Log Groups — three audit sources, pre-created in Phase 2
# Phase 3 (fluent-bit) ships logs into these groups by ARN reference.
#-------------------------------------------------------------------------------

locals {
  # Per CONTEXT decision — exact names referenced verbatim in
  # infrastructure/docs/audit-correlation-queries.md and downstream fluent-bit configs.
  audit_log_sources = ["vault-audit", "ivia-decision", "agent-trace"]
}

resource "aws_cloudwatch_log_group" "workshop_audit" {
  for_each = toset(local.audit_log_sources)

  name              = "/workshop/${each.key}"
  retention_in_days = var.audit_retention_days
  kms_key_id        = aws_kms_key.workshop.arn

  tags = merge(var.tags, {
    source = each.key
  })

  # CMK key policy must exist before the log group attempts to use it.
  depends_on = [aws_kms_key.workshop]
}

#-------------------------------------------------------------------------------
# Glue Catalog Database — schema registry for cross-plane Athena queries
# Empty in Phase 2; Phase 6 adds tables (CloudTrail + per-plane log shapes
# finalize then per RESEARCH Open Question 4).
#-------------------------------------------------------------------------------

resource "aws_glue_catalog_database" "workshop_logs" {
  name        = "workshop_logs"
  description = "Cross-plane audit-correlation database for workshop log analysis via Athena."
}

#-------------------------------------------------------------------------------
# Athena Query Results Bucket — workshop CMK SSE
#-------------------------------------------------------------------------------

resource "aws_s3_bucket" "athena_results" {
  bucket_prefix = "workshop-athena-"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.workshop.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#-------------------------------------------------------------------------------
# Athena Workgroup — workshop default; cross-plane audit-correlation queries.
#-------------------------------------------------------------------------------

resource "aws_athena_workgroup" "workshop" {
  name = "workshop"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.workshop.arn
      }
    }
  }

  force_destroy = true
  tags          = var.tags
}
