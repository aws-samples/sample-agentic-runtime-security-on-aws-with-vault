################################################################################
# RDS Module — PostgreSQL 17 with pgaudit + connection logging
#
# Ships the workshop's relational store, which serves three roles:
#   1. Vault PostgreSQL secrets engine backend (Phase 3)         — dynamic creds
#   2. UC1/UC2/UC3 agent application schema (Phase 4-6)          — RBAC pedagogy
#   3. Audit-correlation source for the data plane (Phase 5-6)   — pgaudit logs
#
# Why bare AWS resources (NOT terraform-aws-modules/rds/aws):
#   The wrapper module hides the subnet group, security group, and CloudWatch
#   log group declarations behind feature flags. This module is small enough
#   that attendee-visible Terraform is the pedagogical asset — see what gets
#   created, not what gets generated. The eks-terraform-stacks reference uses
#   the same bare-resource pattern for similar transparency.
#
# Encryption-context consistency: storage_encrypted, master_user_secret_kms_key_id,
# and the pre-created CloudWatch log group all use the same workshop CMK from
# the audit module — Pattern 6 (RESEARCH.md). Pre-creating the log group with
# Terraform ownership is Pitfall R3 mitigation: RDS would auto-create it on
# first export with the AWS-managed log key, breaking the consistent CMK story.
#
# Reference: RESEARCH.md Pattern 5 + Pitfalls R1 (pgaudit reboot), R2 (log
# scope), R3 (log group ownership).
################################################################################

#-------------------------------------------------------------------------------
# Subnet group — RDS lives in private subnets only (publicly_accessible=false).
#-------------------------------------------------------------------------------

resource "aws_db_subnet_group" "pg17" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.identifier}-subnet-group"
  })
}

#-------------------------------------------------------------------------------
# Security group — :5432 ingress only from the EKS cluster security group.
# Source-SG rule (NOT cidr_blocks) is the load-bearing :5432-from-EKS contract.
#-------------------------------------------------------------------------------

resource "aws_security_group" "pg17" {
  name        = "${var.identifier}-rds-sg"
  description = "PostgreSQL 17 ingress from EKS cluster security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.identifier}-rds-sg"
  })
}

resource "aws_security_group_rule" "pg17_ingress_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.pg17.id
  source_security_group_id = var.cluster_security_group_id
  description              = "Allow :5432 from EKS cluster security group"
}

resource "aws_security_group_rule" "pg17_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.pg17.id
  description       = "Egress all (RDS does not initiate connections in practice)"
}

#-------------------------------------------------------------------------------
# CloudWatch log group — pre-created with workshop CMK (Pitfall R3).
# RDS would otherwise auto-create this group on first export with the AWS-managed
# logs key, breaking the consistent encryption-context story established by the
# audit module's workshop CMK reuse pattern.
#-------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${var.identifier}/postgresql"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.workshop_cmk_arn

  tags = merge(var.tags, {
    source = "rds-postgresql"
  })
}

#-------------------------------------------------------------------------------
# RDS PostgreSQL 17 instance
# Single-AZ (workshop ephemeral; CONTEXT.md decision), private-subnet only,
# storage encryption via workshop CMK, master password RDS-managed -> Secrets
# Manager (bootstrap-only secret; Vault is the runtime credential broker).
#-------------------------------------------------------------------------------

resource "aws_db_instance" "pg17" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.instance_class

  # Storage — gp3 for predictable IO; 50 GiB workshop-sized headroom.
  allocated_storage = 50
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = var.workshop_cmk_arn

  # Database + master user (RDS-managed -> Secrets Manager).
  db_name                       = "workshop"
  username                      = "vault_root"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.workshop_cmk_arn

  # Custom parameter group enables pgaudit + connection logging (see parameter_group.tf).
  parameter_group_name = aws_db_parameter_group.pg17_audit.name

  # Log exports — postgresql carries pgaudit output (PG17 emits pgaudit inline,
  # NOT a separate stream); upgrade captures engine-version transition events.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Workshop topology — single-AZ, private-only, no final snapshot, no deletion lock.
  multi_az            = false
  publicly_accessible = false
  db_subnet_group_name   = aws_db_subnet_group.pg17.name
  vpc_security_group_ids = [aws_security_group.pg17.id]

  # Workshop ephemeral hygiene.
  skip_final_snapshot = true
  deletion_protection = false

  # apply_immediately=true acknowledges the ~10-minute first-apply window for
  # the pgaudit shared_preload_libraries reboot — Pitfall R1. Workshop attendees
  # are willing to take that downtime once at deploy time.
  apply_immediately = true

  # Force the pre-created CloudWatch log group to exist before the first export.
  depends_on = [aws_cloudwatch_log_group.rds_postgresql]

  tags = var.tags
}
