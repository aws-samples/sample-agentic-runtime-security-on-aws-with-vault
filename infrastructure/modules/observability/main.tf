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
#      cloudtrail_events in the existing workshop_logs database.
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
# Log group name is the RDS-managed CloudWatch export group for the instance;
# var.rds_identifier interpolation only — no region literal (canonical contract).
resource "aws_cloudwatch_log_subscription_filter" "pgaudit" {
  name            = "${var.cluster_name}-pgaudit"
  log_group_name  = "/aws/rds/instance/${var.rds_identifier}/postgresql"
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
    # P3 (2026-05-24, live audit line): a database/creds/uc3-refund-writer READ
    # response carries ONLY data:{username,password} plus secret:{lease_id}. The
    # numeric lease_duration that RESEARCH assumed at response.data['lease_duration']
    # is NOT present in the audit-logged response. response.secret.lease_id is the
    # only TTL-adjacent field actually emitted, so the struct models it and the VIEW
    # surfaces db_credential_ttl from response.secret.lease_id (Task 4).
    columns {
      name = "response"
      type = "struct<data:map<string,string>,secret:struct<lease_id:string>>"
    }
  }
}

# PLANE-A (UC3 three-plane audit): RDS pgaudit log lines as raw text.
# Two-column workshop schema (timestamp, message); LazySimpleSerDe over the
# pgaudit/ prefix in the existing KMS-encrypted logs bucket (T-071-05: no new
# bucket, no public path; refund INSERT SQL carries no secrets). The VIEW
# regexp-extracts uc3_request_id and db_table/db_statement from message.
resource "aws_glue_catalog_table" "pgaudit_logs" {
  name          = "pgaudit_logs"
  database_name = var.glue_database_name
  description   = "RDS PostgreSQL pgaudit log lines — data-write audit for UC3 refund INSERT with request_id SQL comment."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"     = "json"
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

    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "message"
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

resource "aws_glue_catalog_table" "cloudtrail_events" {
  name          = "cloudtrail_events"
  database_name = var.glue_database_name
  description   = "AWS CloudTrail management events — correlates AWS API calls with agent request_id via requestParameters match."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"     = "json"
    "EXTERNAL"           = "TRUE"
    "has_encrypted_data" = "false"
    "projection.enabled" = "false"
  }

  storage_descriptor {
    # CloudTrail S3 path pattern — attendees set the actual bucket name via
    # the CloudTrail console or the audit module's existing trail.
    # Using the log export bucket for workshop simplicity; a full CloudTrail
    # integration would point to the org-level trail bucket.
    location      = "${local.log_bucket_uri}/cloudtrail/"
    input_format  = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "ignore.malformed.json" = "TRUE"
      }
    }

    columns {
      name = "eventtime"
      type = "string"
    }
    columns {
      name = "eventname"
      type = "string"
    }
    columns {
      name = "useridentity"
      type = "struct<type:string,principalid:string,arn:string,accountid:string,sessioncontext:struct<sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>>>"
    }
    columns {
      name = "requestparameters"
      type = "string"
    }
    columns {
      name = "responseelements"
      type = "string"
    }
    columns {
      name = "sourceipaddress"
      type = "string"
    }
  }
}

#-------------------------------------------------------------------------------
# Athena named query — audit_correlation VIEW
#
# Mechanism: aws_athena_named_query stores the CREATE OR REPLACE VIEW DDL.
# Attendees retrieve and execute it in the Athena console (lab step).
# This avoids the null_resource/local-exec approach which would require
# attendees to have Athena permissions on the workshop workspace from the
# Terraform apply context — unreliable in Workshop Studio.
#
# The SELECT query is also exposed via output.athena_correlation_query so
# scripts/verify-uc3.sh can inject it directly.
#-------------------------------------------------------------------------------

locals {
  athena_view_sql = <<-SQL
    CREATE OR REPLACE VIEW audit_correlation AS
    SELECT
        a.request_id,
        a.timestamp       AS event_time,
        i.user_identity   AS user_approved,
        a.agent_identity  AS agent_acted,
        a.action_details  AS action,
        a.tool_name       AS tool_used,
        v.request.path    AS vault_path,
        v.auth.policies   AS vault_policies,
        c.eventname       AS cloudtrail_event,
        c.sourceipaddress AS source_ip
    FROM agent_traces a
    LEFT JOIN ivia_decisions i
      ON i.request_id = a.request_id
    LEFT JOIN vault_audit v
      ON v.request.id = a.request_id
    LEFT JOIN cloudtrail_events c
      ON c.requestparameters LIKE '%' || a.request_id || '%'
  SQL

  # SELECT query for verify script consumption (excludes the DDL wrapper)
  athena_select_sql = <<-SQL
    SELECT
        a.request_id,
        a.timestamp       AS event_time,
        i.user_identity   AS user_approved,
        a.agent_identity  AS agent_acted,
        a.action_details  AS action,
        a.tool_name       AS tool_used,
        v.request.path    AS vault_path,
        c.eventname       AS cloudtrail_event
    FROM agent_traces a
    LEFT JOIN ivia_decisions i ON i.request_id = a.request_id
    LEFT JOIN vault_audit v    ON v.request.id = a.request_id
    LEFT JOIN cloudtrail_events c
      ON c.requestparameters LIKE '%' || a.request_id || '%'
    LIMIT 100
  SQL
}

resource "aws_athena_named_query" "audit_correlation_view" {
  name        = "create-audit-correlation-view"
  workgroup   = var.athena_workgroup
  database    = var.glue_database_name
  description = "Creates the audit_correlation VIEW joining agent_traces, ivia_decisions, vault_audit, and cloudtrail_events on W3C traceparent request_id. Execute this in Athena before running correlation queries."
  query       = local.athena_view_sql
}
