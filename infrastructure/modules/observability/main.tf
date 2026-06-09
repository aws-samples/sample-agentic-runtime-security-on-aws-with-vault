################################################################################
# Observability Module — Three-Plane Audit Correlation Infrastructure
#
# Deploys:
#   1. fluent-bit DaemonSet (aws-for-fluent-bit Helm chart) — routes pod logs
#      from vault-*, iviaop-*, uc3-agent-* containers to the pre-created
#      /workshop/* CloudWatch log groups (audit module owns lifecycle).
#   2. IAM role for fluent-bit with Pod Identity association — CloudWatch write.
#   3. S3 bucket for log export with lifecycle and workshop CMK SSE.
#   4. Kinesis Data Firehose delivery streams (3) — one per /workshop/* log group.
#      Each stream delivers to a dedicated S3 prefix.
#   5. CloudWatch subscription filters (3) — one per log group → Firehose stream.
#   6. IAM roles for Firehose (write S3) and CloudWatch (put-records to Firehose).
#   7. Glue catalog tables (4) — vault_audit, ivia_decisions, agent_traces,
#      pgaudit_logs in the existing workshop_logs database.
#   8. Athena named query (audit_correlation_view) — attendees execute this
#      CREATE OR REPLACE VIEW to instantiate the cross-plane JOIN.
#
# IMPORTANT:
#   - CloudWatch log groups and Glue database are owned by the audit module.
#     This module references them by name, NEVER creates them.
#   - KMS key (alias/workshop-data) is also audit-module owned.
#     Passed in as var.kms_key_arn.
################################################################################

data "aws_caller_identity" "this" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

#-------------------------------------------------------------------------------
# Kubernetes namespace for fluent-bit
#-------------------------------------------------------------------------------

resource "kubernetes_namespace" "logging" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

#-------------------------------------------------------------------------------
# IAM role for fluent-bit Pod Identity
# Scoped to /workshop/* CloudWatch log groups.
#-------------------------------------------------------------------------------

data "aws_iam_policy_document" "fluent_bit_assume" {
  statement {
    sid     = "AllowEKSPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "fluent_bit_cw" {
  statement {
    sid = "CloudWatchLogsWorkshop"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:log-group:/workshop/*",
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:log-group:/workshop/*:*",
    ]
  }
}

resource "aws_iam_role" "fluent_bit" {
  name               = "${var.cluster_name}-fluent-bit"
  assume_role_policy = data.aws_iam_policy_document.fluent_bit_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "fluent_bit_cw" {
  name   = "cloudwatch-workshop"
  role   = aws_iam_role.fluent_bit.id
  policy = data.aws_iam_policy_document.fluent_bit_cw.json
}

resource "aws_eks_pod_identity_association" "fluent_bit" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluent_bit.arn

  depends_on = [kubernetes_namespace.logging]
}

#-------------------------------------------------------------------------------
# fluent-bit Helm release (aws-for-fluent-bit chart)
#-------------------------------------------------------------------------------

resource "helm_release" "fluent_bit" {
  name       = "aws-for-fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  namespace  = var.namespace
  version    = "0.2.0"

  values = [
    templatefile("${path.module}/templates/fluent-bit-values.yaml.tpl", {
      region = var.region
    })
  ]

  depends_on = [
    kubernetes_namespace.logging,
    aws_eks_pod_identity_association.fluent_bit,
  ]
}

#-------------------------------------------------------------------------------
# S3 bucket for log export (Firehose destination)
#-------------------------------------------------------------------------------

resource "aws_s3_bucket" "logs" {
  bucket        = var.log_bucket_name
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-workshop-logs"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = 30
    }
  }
}

#-------------------------------------------------------------------------------
# IAM role for Kinesis Firehose → S3
#-------------------------------------------------------------------------------

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    sid     = "AllowFirehose"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "firehose_s3" {
  statement {
    sid = "WriteToLogsBucket"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]
  }

  statement {
    sid = "KmsForLogsBucket"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.cluster_name}-firehose-logs"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "firehose_s3" {
  name   = "s3-workshop-logs"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose_s3.json
}

#-------------------------------------------------------------------------------
# IAM role for CloudWatch Logs → Firehose
#-------------------------------------------------------------------------------

data "aws_iam_policy_document" "cw_firehose_assume" {
  statement {
    sid     = "AllowCWLogs"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:*",
      ]
    }
  }
}

data "aws_iam_policy_document" "cw_to_firehose" {
  statement {
    sid = "PutRecordsToFirehose"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [
      aws_kinesis_firehose_delivery_stream.vault_audit.arn,
      aws_kinesis_firehose_delivery_stream.ivia_decision.arn,
      aws_kinesis_firehose_delivery_stream.agent_trace.arn,
      aws_kinesis_firehose_delivery_stream.pgaudit.arn,
    ]
  }
}

resource "aws_iam_role" "cw_firehose" {
  name               = "${var.cluster_name}-cw-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.cw_firehose_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "cw_to_firehose" {
  name   = "put-records"
  role   = aws_iam_role.cw_firehose.id
  policy = data.aws_iam_policy_document.cw_to_firehose.json
}

#-------------------------------------------------------------------------------
# Kinesis Data Firehose delivery streams (3)
# Each stream buffers for 60s / 5MB then delivers to S3 prefix.
#-------------------------------------------------------------------------------

resource "aws_kinesis_firehose_delivery_stream" "vault_audit" {
  name        = "${var.cluster_name}-vault-audit"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.logs.arn
    prefix              = "vault-audit/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/vault-audit/"

    buffering_interval = 60
    buffering_size     = 5

    compression_format = "UNCOMPRESSED"

    # Unwrap the gzipped CloudWatch Logs DATA_MESSAGE envelope so the inner
    # logEvents[].message (the real record) lands in S3. Without this Firehose
    # writes the envelope verbatim, the Glue tables parse the wrapper instead of
    # the record, every real column is NULL, and the audit_correlation VIEW
    # returns zero rows (Task 3B — root cause verified live 2026-05-24).
    # Processor 1 gunzips (Decompression/GZIP); processor 2 extracts each log
    # event's message (CloudWatchLogProcessing/DataMessageExtraction). Type,
    # parameter_name, and parameter_value all confirmed against the Firehose
    # Processor / ProcessorParameter API enums.
    processing_configuration {
      enabled = true

      processors {
        type = "Decompression"
        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }

      processors {
        type = "CloudWatchLogProcessing"
        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }

    cloudwatch_logging_options {
      enabled = false
    }
  }

  tags = var.tags
}

resource "aws_kinesis_firehose_delivery_stream" "ivia_decision" {
  name        = "${var.cluster_name}-ivia-decision"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.logs.arn
    prefix              = "ivia-decision/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/ivia-decision/"

    buffering_interval = 60
    buffering_size     = 5

    compression_format = "UNCOMPRESSED"

    # Unwrap the gzipped CloudWatch Logs DATA_MESSAGE envelope so the inner
    # logEvents[].message (the real record) lands in S3. Without this Firehose
    # writes the envelope verbatim, the Glue tables parse the wrapper instead of
    # the record, every real column is NULL, and the audit_correlation VIEW
    # returns zero rows (Task 3B — root cause verified live 2026-05-24).
    # Processor 1 gunzips (Decompression/GZIP); processor 2 extracts each log
    # event's message (CloudWatchLogProcessing/DataMessageExtraction). Type,
    # parameter_name, and parameter_value all confirmed against the Firehose
    # Processor / ProcessorParameter API enums.
    processing_configuration {
      enabled = true

      processors {
        type = "Decompression"
        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }

      processors {
        type = "CloudWatchLogProcessing"
        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }

    cloudwatch_logging_options {
      enabled = false
    }
  }

  tags = var.tags
}

resource "aws_kinesis_firehose_delivery_stream" "agent_trace" {
  name        = "${var.cluster_name}-agent-trace"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.logs.arn
    prefix              = "agent-trace/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/agent-trace/"

    buffering_interval = 60
    buffering_size     = 5

    compression_format = "UNCOMPRESSED"

    # Unwrap the gzipped CloudWatch Logs DATA_MESSAGE envelope so the inner
    # logEvents[].message (the real record) lands in S3. Without this Firehose
    # writes the envelope verbatim, the Glue tables parse the wrapper instead of
    # the record, every real column is NULL, and the audit_correlation VIEW
    # returns zero rows (Task 3B — root cause verified live 2026-05-24).
    # Processor 1 gunzips (Decompression/GZIP); processor 2 extracts each log
    # event's message (CloudWatchLogProcessing/DataMessageExtraction). Type,
    # parameter_name, and parameter_value all confirmed against the Firehose
    # Processor / ProcessorParameter API enums.
    processing_configuration {
      enabled = true

      processors {
        type = "Decompression"
        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }

      processors {
        type = "CloudWatchLogProcessing"
        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }

    cloudwatch_logging_options {
      enabled = false
    }
  }

  tags = var.tags
}

# PLANE-A (UC3 three-plane audit): dedicated stream for RDS pgaudit lines.
# A NEW stream rather than reusing an existing one — the RDS postgresql log
# source has a different line shape than the JSON sources above; a dedicated
# stream lands raw text at the pgaudit/ prefix for the LazySimpleSerDe Glue
# table (RESEARCH Open Question 3 RESOLVED).
resource "aws_kinesis_firehose_delivery_stream" "pgaudit" {
  name        = "${var.cluster_name}-pgaudit"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.logs.arn
    prefix              = "pgaudit/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/pgaudit/"

    buffering_interval = 60
    buffering_size     = 5

    compression_format = "UNCOMPRESSED"

    # Unwrap the gzipped CloudWatch Logs DATA_MESSAGE envelope so the inner
    # logEvents[].message (the real record) lands in S3. Without this Firehose
    # writes the envelope verbatim, the Glue tables parse the wrapper instead of
    # the record, every real column is NULL, and the audit_correlation VIEW
    # returns zero rows (Task 3B — root cause verified live 2026-05-24).
    # Processor 1 gunzips (Decompression/GZIP); processor 2 extracts each log
    # event's message (CloudWatchLogProcessing/DataMessageExtraction). Type,
    # parameter_name, and parameter_value all confirmed against the Firehose
    # Processor / ProcessorParameter API enums.
    processing_configuration {
      enabled = true

      processors {
        type = "Decompression"
        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }

      processors {
        type = "CloudWatchLogProcessing"
        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }

    cloudwatch_logging_options {
      enabled = false
    }
  }

  tags = var.tags
}

#-------------------------------------------------------------------------------
# CloudWatch subscription filters (3)
# One per /workshop/* log group → corresponding Firehose delivery stream.
#-------------------------------------------------------------------------------

resource "aws_cloudwatch_log_subscription_filter" "vault_audit" {
  name            = "${var.cluster_name}-vault-audit"
  log_group_name  = "/workshop/vault-audit"
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.vault_audit.arn
  role_arn        = aws_iam_role.cw_firehose.arn
  distribution    = "ByLogStream"

  depends_on = [aws_iam_role_policy.cw_to_firehose]
}

resource "aws_cloudwatch_log_subscription_filter" "ivia_decision" {
  name            = "${var.cluster_name}-ivia-decision"
  log_group_name  = "/workshop/ivia-decision"
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.ivia_decision.arn
  role_arn        = aws_iam_role.cw_firehose.arn
  distribution    = "ByLogStream"

  depends_on = [aws_iam_role_policy.cw_to_firehose]
}

resource "aws_cloudwatch_log_subscription_filter" "agent_trace" {
  name            = "${var.cluster_name}-agent-trace"
  log_group_name  = "/workshop/agent-trace"
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.agent_trace.arn
  role_arn        = aws_iam_role.cw_firehose.arn
  distribution    = "ByLogStream"

  depends_on = [aws_iam_role_policy.cw_to_firehose]
}

# PLANE-A: subscribe the RDS PostgreSQL/pgaudit log group to the pgaudit Firehose.
# Log group name is the authoritative pre-created RDS export group passed in from
# the rds module — never reconstructed from a resource ID (no region literal).
resource "aws_cloudwatch_log_subscription_filter" "pgaudit" {
  name            = "${var.cluster_name}-pgaudit"
  log_group_name  = var.rds_postgresql_log_group_name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.pgaudit.arn
  role_arn        = aws_iam_role.cw_firehose.arn
  distribution    = "ByLogStream"

  depends_on = [aws_iam_role_policy.cw_to_firehose]
}

#-------------------------------------------------------------------------------
# Glue catalog tables in existing workshop_logs database
# JSON SerDe — matches structured JSON emitted by Vault audit device,
# IVIA decision logger, and the UC3 Strands agent OTel stdout exporter.
# CloudTrail table points to the account-level CloudTrail S3 path.
#-------------------------------------------------------------------------------

locals {
  # S3 location base for Glue tables — Firehose delivers here.
  log_bucket_uri = "s3://${aws_s3_bucket.logs.id}"
}

resource "aws_glue_catalog_table" "vault_audit" {
  name          = "vault_audit"
  database_name = var.glue_database_name
  description   = "HashiCorp Vault audit device JSON log events — request + response per Vault operation."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"     = "json"
    "EXTERNAL"           = "TRUE"
    "has_encrypted_data" = "false"
  }

  storage_descriptor {
    location      = "${local.log_bucket_uri}/vault-audit/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "ignore.malformed.json" = "TRUE"
        # Pre-2026-05-24 objects in these prefixes are gzipped CloudWatch-Logs
        # DATA_MESSAGE envelopes written before Task 3B added Firehose
        # decompression. The OpenX JSON SerDe reads those raw gzip bytes as text
        # and fails with "Primitive can not be coerced to a ROW" on struct
        # columns; ignore.malformed.json does NOT cover that case. This property
        # makes the SerDe emit NULL for unparseable rows instead, so the old
        # envelope objects become all-NULL (dropped by the VIEW's INNER JOIN)
        # while new unwrapped records parse normally. Recommended by Athena's
        # own error message (openx-json-serde docs).
        "use.null.for.invalid.data" = "true"
        # Vault audit records carry the event timestamp under the JSON key "time",
        # but the Athena column is named "timestamp" (matches the other audit
        # tables). Map the column to the real key so vault_auth_time populates;
        # without this the column reads NULL and the audit_correlation VIEW cannot
        # time-window the Vault cred issuance to a single CIBA request.
        "mapping.timestamp" = "time"
      }
    }

    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "type"
      type = "string"
    }
    columns {
      name = "auth"
      type = "struct<client_token:string,accessor:string,display_name:string,policies:array<string>,metadata:map<string,string>>"
    }
    columns {
      name = "request"
      type = "struct<id:string,path:string,operation:string,namespace:struct<id:string>,data:map<string,string>>"
    }
    columns {
      name = "response"
      type = "struct<data:map<string,string>>"
    }
  }
}

# PLANE-A (UC3 three-plane audit): RDS pgaudit log lines as raw text.
# Single-column schema (line); LazySimpleSerDe over the pgaudit/ prefix in the
# existing KMS-encrypted logs bucket (T-071-05: no new bucket, no public path;
# refund INSERT SQL carries no secrets). The VIEW regexp-extracts uc3_request_id
# (join key), db_write_time, and db_command (WRITE,INSERT) from `line`.
resource "aws_glue_catalog_table" "pgaudit_logs" {
  name          = "pgaudit_logs"
  database_name = var.glue_database_name
  description   = "RDS PostgreSQL pgaudit log lines — data-write audit for UC3 refund INSERT with request_id SQL comment."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"     = "csv"
    "EXTERNAL"           = "TRUE"
    "has_encrypted_data" = "false"
  }

  storage_descriptor {
    location      = "${local.log_bucket_uri}/pgaudit/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "raw-text-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
    }

    # pgaudit records are raw PostgreSQL log TEXT lines (not JSON), so the table
    # is a SINGLE honest column holding the whole line. The VIEW regex-extracts
    # db_write_time, db_command (e.g. WRITE,INSERT) and the uc3_request_id join
    # key from `line`. A 2-column (timestamp,message) shape was wrong: with the
    # LazySimpleSerDe default delimiter the entire line lands in column 1 and the
    # second column is always NULL — so VIEW regexes over `message` matched nothing.
    columns {
      name = "line"
      type = "string"
    }
  }
}

resource "aws_glue_catalog_table" "ivia_decisions" {
  name          = "ivia_decisions"
  database_name = var.glue_database_name
  description   = "IBM Verify Identity Access CIBA decision log events — authorization decisions with request context."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"     = "json"
    "EXTERNAL"           = "TRUE"
    "has_encrypted_data" = "false"
  }

  storage_descriptor {
    location      = "${local.log_bucket_uri}/ivia-decision/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "ignore.malformed.json" = "TRUE"
        # Pre-2026-05-24 objects in these prefixes are gzipped CloudWatch-Logs
        # DATA_MESSAGE envelopes written before Task 3B added Firehose
        # decompression. The OpenX JSON SerDe reads those raw gzip bytes as text
        # and fails with "Primitive can not be coerced to a ROW" on struct
        # columns; ignore.malformed.json does NOT cover that case. This property
        # makes the SerDe emit NULL for unparseable rows instead, so the old
        # envelope objects become all-NULL (dropped by the VIEW's INNER JOIN)
        # while new unwrapped records parse normally. Recommended by Athena's
        # own error message (openx-json-serde docs).
        "use.null.for.invalid.data" = "true"
      }
    }

    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "request_id"
      type = "string"
    }
    columns {
      name = "user_identity"
      type = "string"
    }
    columns {
      name = "decision"
      type = "string"
    }
    columns {
      name = "client_id"
      type = "string"
    }
    columns {
      name = "grant_type"
      type = "string"
    }
    columns {
      name = "authorization_details"
      type = "array<struct<type:string,actions:array<string>,amount:string,currency:string>>"
    }
    # The REAL numeric lease TTL in seconds (e.g. 300 = 5 min) the agent OBSERVED
    # when Vault issued the per-refund uc3-refund-writer credential. Emitted by the
    # agent's Branch-B ivia_decisions anchor record (agent.py decision_record), sourced
    # from the hvac db_response.lease_duration. The Vault audit-logged response carries
    # ONLY a lease-id identifier (not a duration), so the agent-observed
    # value is the only honest numeric TTL — the VIEW surfaces db_credential_ttl from here
    # (request_id-keyed via the ivia anchor), proving OBJ-2 (no standing privileges).
    columns {
      name = "db_credential_ttl"
      type = "int"
    }
  }
}

resource "aws_glue_catalog_table" "agent_traces" {
  name          = "agent_traces"
  database_name = var.glue_database_name
  description   = "UC3 Strands agent OTel trace events — per-action span data with request_id propagated via W3C traceparent."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"     = "json"
    "EXTERNAL"           = "TRUE"
    "has_encrypted_data" = "false"
  }

  storage_descriptor {
    location      = "${local.log_bucket_uri}/agent-trace/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "ignore.malformed.json" = "TRUE"
        # Pre-2026-05-24 objects in these prefixes are gzipped CloudWatch-Logs
        # DATA_MESSAGE envelopes written before Task 3B added Firehose
        # decompression. The OpenX JSON SerDe reads those raw gzip bytes as text
        # and fails with "Primitive can not be coerced to a ROW" on struct
        # columns; ignore.malformed.json does NOT cover that case. This property
        # makes the SerDe emit NULL for unparseable rows instead, so the old
        # envelope objects become all-NULL (dropped by the VIEW's INNER JOIN)
        # while new unwrapped records parse normally. Recommended by Athena's
        # own error message (openx-json-serde docs).
        "use.null.for.invalid.data" = "true"
      }
    }

    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "request_id"
      type = "string"
    }
    columns {
      name = "agent_identity"
      type = "string"
    }
    columns {
      name = "action_details"
      type = "string"
    }
    columns {
      name = "tool_name"
      type = "string"
    }
    columns {
      name = "status"
      type = "string"
    }
  }
}

#-------------------------------------------------------------------------------
# audit_correlation VIEW — DDL source of truth + auto-creation
#
# Two resources cooperate, both fed from the single local.athena_view_sql:
#   1. aws_athena_named_query.audit_correlation_view STORES the CREATE OR REPLACE
#      VIEW DDL as a named query — the Athena-console/manual fallback and the DDL
#      that scripts/verify-uc3.sh retrieves and re-runs.
#   2. null_resource.audit_correlation_view EXECUTES that same DDL via the AWS CLI
#      during `terraform apply` (tier-1, deploy-workshop.sh Step 1) so the VIEW
#      exists in the workshop_logs catalog the moment an attendee reaches the audit
#      page — honoring the content's "created automatically during deployment".
#
# The apply runs in the DEPLOYER's context (full Athena permissions), NOT an
# attendee's, so the earlier Workshop-Studio objection (attendees lack Athena
# perms from their own apply context) does not apply.
#-------------------------------------------------------------------------------

locals {
  # 12-column audit_correlation VIEW (CONTEXT Delta-6, Option B — locked 2026-05-24;
  # CloudTrail plane removed 2026-05-25 — see SUMMARY: no workshop-owned trail delivers
  # to S3 in a fresh attendee account, and the refund is a Postgres write CloudTrail
  # never witnesses; the three planes IVIA + Vault + pgaudit fully satisfy OBJ-5).
  # Anchored on ivia_decisions via INNER JOIN: the agent's Branch-B emission (Task 2b)
  # MUST populate >=1 row per request_id or the whole capstone returns zero rows.
  #
  # Probe-driven decisions baked in here (results in 07.1-capstone-SUMMARY.md):
  #   P1 = NO/DEFERRED -> ship the SAFE Alt-A vault join: anchor ivia_decisions, join
  #        vault_audit on the principal. VERIFIED 2026-05-24 against live unwrapped
  #        records: the Vault JWT-auth display_name is 'jwt-<sub>' (e.g. jwt-oscar),
  #        NOT the bare sub, so the join key is vault.auth.display_name = 'jwt-' ||
  #        ivia.user_identity. The join is further scoped to the refund-writer cred
  #        path (request.path = 'database/creds/uc3-refund-writer') and to the
  #        completed operation (vault.type = 'response') so a single cred issuance
  #        yields exactly one row instead of fanning out across the request+response
  #        audit pair, then bounded to a 30s window of the approval. The vault.timestamp
  #        column is SerDe-mapped to the record's "time" key (mapping.timestamp=time on
  #        the vault_audit Glue table) — without that map the column reads NULL and the
  #        time window cannot fire. Metadata surfaced via MAP BRACKET syntax. Alt-D (a true request_id
  #        JWT claim join: vault.auth.metadata['request_id'] = ivia.request_id) was
  #        probed and is the documented UPGRADE PATH — it needs binding_message/
  #        request_id injected into the isvaop_pretoken stsuu context as a top-level
  #        JWT claim AND added to the uc3-jwt claim_mappings. NOT shipped (would yield
  #        zero rows until that IVIA mutation lands).
  #   P2 = pgaudit Fork B (chosen 2026-05-25). The agent's INSERT is a MULTI-LINE
  #        statement, and the log pipeline splits it on newlines into separate S3 rows,
  #        so the row carrying the uc3_request_id comment also carries the AUDIT header
  #        and the WRITE,INSERT command — but NOT the table name (pgaudit.log_relation
  #        is off -> OBJNAME field blank) nor the full quoted SQL (its closing quote is
  #        on a later split row). So the VIEW surfaces only what one row honestly proves:
  #        db_write_time (leading 'YYYY-MM-DD HH:MM:SS UTC' prefix) and db_command
  #        (the WRITE,INSERT operation), with the uc3_request_id regex as the join key.
  #        db_table/db_statement were DROPPED rather than shipped blank. The richer
  #        forensic variant (Fork A: pgaudit.log_relation=1 + single-line agent INSERT)
  #        is the documented upgrade path — it needs an agent rebuild + a new refund.
  #   P3 = the database/creds READ audit response does NOT carry a numeric lease TTL
  #        (only a lease-id identifier — NOT a duration; and numeric
  #        lease_duration is NOT logged at response.data['lease_duration'] either). The
  #        only honest numeric TTL is the value the AGENT itself observed in the hvac
  #        creds response (db_response.lease_duration, e.g. 300). The agent threads it
  #        into its Branch-B ivia_decisions anchor record (db_credential_ttl), so the
  #        VIEW surfaces db_credential_ttl from ivia.db_credential_ttl, request_id-keyed.
  athena_view_sql = <<-SQL
    CREATE OR REPLACE VIEW audit_correlation AS
    SELECT
        ivia.request_id,
        ivia.timestamp                                                AS approval_time,
        ivia.user_identity                                            AS user_approved_sub,
        ivia.request_id                                               AS ciba_binding_message,
        vault.timestamp                                               AS vault_auth_time,
        vault.auth.display_name                                       AS vault_principal,
        vault.request.path                                            AS vault_path,
        vault.auth.metadata['may_act_sub']                            AS vault_bound_claim_may_act,
        vault.auth.metadata['rar_type']                               AS vault_bound_claim_rar_type,
        regexp_extract(rds.line, '^([0-9-]+ [0-9:]+ UTC)', 1)        AS db_write_time,
        regexp_extract(rds.line, 'AUDIT: SESSION,[0-9]+,[0-9]+,([A-Z]+,[A-Z]+),', 1) AS db_command,
        ivia.db_credential_ttl                                        AS db_credential_ttl
    FROM workshop_logs.ivia_decisions ivia
    JOIN workshop_logs.vault_audit vault
        ON vault.auth.display_name = 'jwt-' || ivia.user_identity
        AND vault.request.path = 'database/creds/uc3-refund-writer'
        AND vault.type = 'response'
        AND ABS(to_unixtime(from_iso8601_timestamp(vault.timestamp))
              - to_unixtime(from_iso8601_timestamp(ivia.timestamp))) < 30
    LEFT JOIN workshop_logs.pgaudit_logs rds
        ON regexp_extract(rds.line, 'uc3_request_id=([0-9a-f-]{36})', 1) = ivia.request_id
  SQL

  # SELECT query for verify-uc3.sh consumption — the verify script substitutes the
  # captured request_id for REPLACE_WITH_REQUEST_ID and asserts exactly one row.
  athena_select_sql = <<-SQL
    SELECT *
    FROM audit_correlation
    WHERE request_id = 'REPLACE_WITH_REQUEST_ID'
    LIMIT 1
  SQL
}

resource "aws_athena_named_query" "audit_correlation_view" {
  name        = "create-audit-correlation-view"
  workgroup   = var.athena_workgroup
  database    = var.glue_database_name
  description = "Stored CREATE OR REPLACE VIEW DDL for audit_correlation (joins ivia_decisions, vault_audit, pgaudit_logs on request_id). Auto-executed at apply by null_resource.audit_correlation_view; also runnable manually in the Athena console."
  query       = local.athena_view_sql
}

# Execute the stored DDL at apply so the VIEW exists automatically (see comment
# above). The 'workshop' workgroup enforces its own result location, so no
# OutputLocation is passed; Database=<glue_database_name> is required because the
# VIEW name in the DDL is unqualified. Idempotent (CREATE OR REPLACE VIEW); the
# trigger re-runs it only when the DDL changes.
resource "null_resource" "audit_correlation_view" {
  triggers = {
    view_sql = local.athena_view_sql
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AWS_REGION = var.region
      WORKGROUP  = var.athena_workgroup
      DATABASE   = var.glue_database_name
      VIEW_SQL   = local.athena_view_sql
    }
    command = <<-EOT
      set -euo pipefail
      qid=$(aws athena start-query-execution \
        --region "$AWS_REGION" \
        --work-group "$WORKGROUP" \
        --query-execution-context "Database=$DATABASE" \
        --query-string "$VIEW_SQL" \
        --query 'QueryExecutionId' --output text)
      echo "audit_correlation VIEW DDL submitted (QueryExecutionId=$qid)"
      for _ in $(seq 1 30); do
        state=$(aws athena get-query-execution --region "$AWS_REGION" \
          --query-execution-id "$qid" \
          --query 'QueryExecution.Status.State' --output text)
        case "$state" in
          SUCCEEDED)
            echo "audit_correlation VIEW created/refreshed in $DATABASE"
            exit 0 ;;
          FAILED|CANCELLED)
            reason=$(aws athena get-query-execution --region "$AWS_REGION" \
              --query-execution-id "$qid" \
              --query 'QueryExecution.Status.StateChangeReason' --output text)
            echo "audit_correlation VIEW creation $state: $reason" >&2
            exit 1 ;;
        esac
        sleep 2
      done
      echo "audit_correlation VIEW creation did not reach SUCCEEDED within 60s" >&2
      exit 1
    EOT
  }

  depends_on = [
    aws_glue_catalog_table.ivia_decisions,
    aws_glue_catalog_table.vault_audit,
    aws_glue_catalog_table.pgaudit_logs,
    aws_athena_named_query.audit_correlation_view,
  ]
}
