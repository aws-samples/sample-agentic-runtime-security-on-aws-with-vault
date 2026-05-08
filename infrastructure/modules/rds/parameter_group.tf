################################################################################
# RDS Module — Custom Parameter Group (postgres17 family)
#
# Enables pgaudit + standard PG connection logging so the RDS audit infrastructure
# stands up in Phase 2 — Phases 5-6 just query it via Athena/Glue against the
# pre-created /aws/rds/instance/<id>/postgresql log group.
#
# Pitfalls addressed:
#   R1: shared_preload_libraries is a STATIC parameter — requires reboot.
#       apply_method = "pending-reboot" + apply_immediately=true on the instance
#       acknowledges the ~10-minute first-apply window.
#   R2: pgaudit.log='all' floods CloudWatch. Workshop scope is 'ddl,write,role'
#       — sufficient for OBJ-5 audit-correlation pedagogy without log noise.
#       pgaudit.log_catalog=off skips system-catalog statement logging.
#
# Reference: RESEARCH.md Pattern 5 + Pitfalls R1 (reboot), R2 (log scope).
################################################################################

resource "aws_db_parameter_group" "pg17_audit" {
  name        = "${var.identifier}-pg17-audit"
  family      = "postgres17"
  description = "Workshop PG17 - pgaudit + connection logging for audit-correlation pedagogy"

  # ---------------------------------------------------------------------------
  # pgaudit shared-library boot (STATIC parameter — Pitfall R1: reboot required)
  # ---------------------------------------------------------------------------
  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit"
    apply_method = "pending-reboot"
  }

  # ---------------------------------------------------------------------------
  # pgaudit scope — 'ddl,write,role' (Pitfall R2: avoid 'all' log floods)
  # ddl   — schema changes (CREATE/ALTER/DROP)
  # write — INSERT/UPDATE/DELETE/COPY (data mutations)
  # role  — GRANT/REVOKE/CREATE ROLE (authz boundary changes)
  # ---------------------------------------------------------------------------
  parameter {
    name  = "pgaudit.log"
    value = "ddl,write,role"
  }

  # Skip system-catalog noise — pgaudit defaults to logging catalog reads which
  # explode log volume without serving the audit-correlation query templates.
  # Use "0" (not "off") — the RDS API normalizes boolean strings to "0"/"1"
  # at storage time, so a TF value of "off" produces perpetual drift on
  # subsequent plans (TF compares "off" to AWS-stored "0"). Seen in stack run
  # sdr-m4miM2QRJasVkSiF (2026-05-08) where this parameter alone caused 10+
  # plan/apply rounds.
  parameter {
    name  = "pgaudit.log_catalog"
    value = "0"
  }

  # ---------------------------------------------------------------------------
  # Standard PG connection logging — INFR-03 explicit requirements
  # ---------------------------------------------------------------------------
  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  # DDL-level statement logging — forensics redundancy that mirrors pgaudit.log=ddl
  # but uses the native PG log_statement path (different log line shape; useful
  # when pgaudit output is being post-processed and DDL needs an out-of-band copy).
  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  tags = var.tags
}
