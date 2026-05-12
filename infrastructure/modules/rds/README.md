# rds

Single-AZ Amazon RDS PostgreSQL 17 with **pgaudit + connection logging enabled in Phase 2**, custom parameter group, CloudWatch log exports for `postgresql` + `upgrade`, storage encryption via the workshop CMK, master password managed by RDS to AWS Secrets Manager, and a security group that admits `:5432` only from the EKS cluster security group.

## Overview

This module ships INFR-03 (PostgreSQL 17 + pgaudit + connection logging + CloudWatch log exports). It serves three downstream roles in the workshop:

1. **Vault PostgreSQL secrets engine backend (Phase 3)** — Vault's dynamic-credential broker connects with the RDS-managed master password, then issues short-lived per-role credentials to agents.
2. **UC1/UC2/UC3 application schema (Phase 4-6)** — agents read and write workshop application data here under Vault-issued credentials.
3. **Audit-correlation source for the data plane (Phase 5-6)** — pgaudit lines land in `/aws/rds/instance/<id>/postgresql` and are JOINed against Vault audit, IVIA decision, and CloudTrail records via the W3C `traceparent` contract documented in [`infrastructure/docs/audit-correlation-queries.md`](../../docs/audit-correlation-queries.md).

Storage encryption, the master-user Secrets Manager secret, and the pre-created CloudWatch log group **all use the workshop CMK** (output `workshop_cmk_arn` from the [`audit`](../audit/README.md) module). This is the encryption-context-consistency story attendees see across Phase 2 — one CMK, multiple consumers (Pattern 6).

## Decisions (locked from `.planning/phases/02-foundation-infrastructure/02-CONTEXT.md`)

- **Engine:** PostgreSQL 17 (latest GA at workshop authoring time).
- **Instance class:** `db.t3.medium` default (≤15 attendees); `db.t3.large` for >15. Configurable via `var.instance_class`, **not pinned**.
- **Topology:** Single-AZ. Multi-AZ is **off** — the workshop is ephemeral; failover is not part of pedagogy.
- **pgaudit enabled in Phase 2** — not deferred. Audit infrastructure stands up early so Phases 5-6 just query it; avoids parameter-group churn (some pgaudit settings require reboot).
- **pgaudit scope:** `pgaudit.log = ddl,write,role` (avoids `all`-level CloudWatch flooding — Pitfall R2). `pgaudit.log_catalog = off` skips system-catalog noise.
- **Connection logging:** `log_connections = 1`, `log_disconnections = 1` (INFR-03 explicit). `log_statement = ddl` mirrors `pgaudit.log=ddl` for forensics redundancy.
- **CloudWatch log exports:** `[postgresql, upgrade]`. PG 17 emits pgaudit output **inline within the postgresql log type** — no separate stream.
- **Storage encryption:** workshop CMK (`var.workshop_cmk_arn` from the `audit` module).
- **Master password:** RDS-managed → AWS Secrets Manager (`manage_master_user_password = true` + `master_user_secret_kms_key_id = workshop CMK`). **Bootstrap-only secret** — Vault is the runtime credential broker; this secret exists so the Phase 3 Vault PostgreSQL engine can do its initial connection.
- **`apply_immediately = true`** — acknowledges the ~10-minute first-apply window for the `pgaudit` shared-preload-libraries reboot (Pitfall R1).
- **CloudWatch log group pre-created** with the workshop CMK (Pitfall R3 mitigation; otherwise RDS auto-creates it on first export with the AWS-managed log key, breaking the consistent-CMK story).
- **Network:** Private subnets only (`publicly_accessible = false`). Security group allows `:5432` ingress from the EKS cluster security group via `source_security_group_id` — **not** `cidr_blocks 0.0.0.0/0`.
- **Database name + master user:** `workshop` / `vault_root`. Hardcoded module-internal — these are workshop-pedagogical constants, not knobs.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `identifier` | string | (required) | RDS instance identifier; prefix for subnet group, security group, parameter group, and log group names. |
| `vpc_id` | string | (required) | VPC ID (output by `module.vpc`). |
| `private_subnet_ids` | list(string) | (required) | Private subnet IDs for the RDS subnet group. |
| `cluster_security_group_id` | string | (required) | EKS cluster security group ID (output by `module.eks`); source of the `:5432` ingress rule. |
| `workshop_cmk_arn` | string | (required) | Workshop CMK ARN (output by `module.audit`). Used for storage, master-user secret, and CloudWatch log group encryption. |
| `instance_class` | string | `db.t3.medium` | RDS instance class. Bump to `db.t3.large` for >15 attendees. |
| `log_retention_days` | number | `7` | CloudWatch log group retention. |
| `tags` | map(string) | `{}` | Tags applied to all resources. |

## Outputs

| Name | Sensitive | Description |
|------|-----------|-------------|
| `endpoint` | no | `<address>:<port>` — Vault and the agents connect here. |
| `address` | no | Bare DNS hostname. |
| `port` | no | `5432`. |
| `db_instance_id` | no | RDS identifier; referenced by Phase 6 audit-correlation queries. |
| `db_security_group_id` | no | RDS security group ID. |
| `master_user_secret_arn` | **yes** | RDS-managed master-user Secrets Manager ARN (bootstrap-only). |
| `db_name` | no | `workshop`. |
| `master_username` | no | `vault_root`. |
| `postgresql_log_group_name` | no | `/aws/rds/instance/<id>/postgresql`. |
| `postgresql_log_group_arn` | no | Log group ARN — used by IAM policies granting pgaudit-log read access. |

## Root module wiring

In `infrastructure/main.tf`, the `rds` module receives:

```hcl
module "rds" {
  source = "./modules/rds"

  depends_on = [module.eks]

  identifier                = "workshop-pg17"
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  cluster_security_group_id = module.eks.cluster_security_group_id
  workshop_cmk_arn          = module.audit.workshop_cmk_arn
  instance_class            = var.rds_instance_class
  tags                      = var.tags
}
```

## First-apply note

**The first `terraform apply` takes ~10 minutes.** `shared_preload_libraries = pgaudit` is a static parameter; RDS must reboot to load the library. `apply_immediately = true` allows the reboot to happen at apply time rather than during the next maintenance window. After apply, validate with:

```bash
psql -h <endpoint> -U vault_root -d workshop -c "SHOW shared_preload_libraries;"
# Expected: pgaudit
```

If the result is empty, the parameter-group reboot has not completed — wait for the instance to return to `available` and retry.

## Pitfalls (RESEARCH.md cross-reference)

- **R1 (pgaudit reboot):** `shared_preload_libraries` is static. `apply_method = "pending-reboot"` on that parameter + `apply_immediately = true` on the instance acknowledge the first-apply downtime.
- **R2 (log scope):** `pgaudit.log = all` floods CloudWatch. Workshop scope `ddl,write,role` is sufficient for OBJ-5 audit-correlation pedagogy without the noise.
- **R3 (log group ownership):** RDS auto-creates `/aws/rds/instance/<id>/postgresql` on first export with the AWS-managed log key, leaving Terraform without ownership and breaking consistent-CMK encryption context. We pre-create the log group with the workshop CMK and use `depends_on` on `aws_db_instance` to enforce ordering.

## References

- [Terraform `aws_db_instance`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance)
- [AWS RDS pgaudit documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.pgaudit.html)
- [`infrastructure/docs/audit-correlation-queries.md`](../../docs/audit-correlation-queries.md) — W3C `traceparent` contract + composite-key Athena join.
- [`infrastructure/modules/audit/README.md`](../audit/README.md) — workshop CMK source.
