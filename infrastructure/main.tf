################################################################################
# Root Module — tier 1 (core infrastructure)
# Agentic Runtime Security Workshop
#
# This root provisions ONLY foundational, pod-free infrastructure. The Vault +
# IVIA server runtimes live in the tier-2 services root (infrastructure/services/)
# and the end-user workloads (uc1/uc2/uc3) live in the tier-3 workloads root
# (infrastructure/workloads/). Each downstream tier reads this root's state via
# terraform_remote_state. deploy-workshop.sh applies the tiers in order:
#   tier 1 (here) → build-images.sh → tier 2 (services) → vault-config → tier 3.
#
# Why three roots instead of one: a single whole-root apply created uc1/uc2/uc3
# workload pods before their out-of-graph prerequisites existed (ECR images from
# build-images.sh + Vault roles from vault-config) → ImagePullBackOff +
# Vault-403 CrashLoop. Splitting the roots makes the provisioning ORDER
# structural (a tier cannot apply until the prior tier's state exists) instead of
# relying on bash -target staging.
#
# What stays in tier 1: VPC, EKS, add-ons (incl. cert-manager + external-dns +
# Let's Encrypt ClusterIssuer = cert-issuance machinery), RDS, Bedrock KB, ECR,
# IAM (incl. the Vault Pod Identity role + KMS unseal key — see module.vault_iam),
# ACM bootstrap cert, EDR, observability. No pods.
#
# Karpenter and ArgoCD are intentionally OUT of scope (managed node group only).
################################################################################

#-------------------------------------------------------------------------------
# Audit
# Foundation: workshop CMK + 3 pre-created CloudWatch log groups
# (/workshop/vault-audit, /workshop/ivia-decision, /workshop/agent-trace)
# + Glue catalog database 'workshop_logs' + Athena workgroup 'workshop'.
#-------------------------------------------------------------------------------

module "audit" {
  source = "./modules/audit"

  region               = var.region
  audit_retention_days = var.audit_retention_days
  tags                 = var.tags
}

#-------------------------------------------------------------------------------
# ECR
# Pre-creates container image repos so build scripts only push (no ad-hoc
# create-repository). force_delete = true for clean terraform destroy.
#-------------------------------------------------------------------------------

module "ecr" {
  source = "./modules/ecr"

  repository_names = ["workshop/uc1-agent", "workshop/uc3-agent", "workshop-banking-app"]
  tags             = var.tags
}

#-------------------------------------------------------------------------------
# TLS — self-signed bootstrap cert for the browser-facing ALB HTTPS listeners.
#
# This resource MINTS the ACM ARN that both attendee-facing ALB Ingresses
# (IVIA WRP in tier 2 + banking-UI in tier 3) bind via the
# `alb.ingress.kubernetes.io/certificate-arn` annotation. At first apply the
# cert content is the self-signed wildcard below; the ACM-sync CronJob (in
# module.addons) then upserts the Let's Encrypt-issued cert body into THIS SAME
# ARN. lifecycle.ignore_changes protects that import from Terraform re-apply.
# The ARN is exported (output tls_certificate_arn) for tier 2 + tier 3 to bind.
#-------------------------------------------------------------------------------

resource "tls_private_key" "workshop_tls" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "workshop_tls" {
  private_key_pem = tls_private_key.workshop_tls.private_key_pem

  subject {
    common_name  = "*.${var.region}.elb.amazonaws.com"
    organization = "Agentic Runtime Security Workshop"
  }

  # Covers both LBC-generated ALB hostnames (banking-ui + ivia-wrp), which take
  # the form k8s-<ns>-<ingress>-<hash>-<num>.<region>.elb.amazonaws.com — a
  # single label before the regional suffix, so the wildcard matches.
  dns_names = ["*.${var.region}.elb.amazonaws.com"]

  validity_period_hours = 8760 # 1 year — far longer than any workshop run

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "workshop_tls" {
  private_key      = tls_private_key.workshop_tls.private_key_pem
  certificate_body = tls_self_signed_cert.workshop_tls.cert_pem
  tags             = var.tags

  lifecycle {
    create_before_destroy = true
    # Protect the cert body from Terraform drift after the ACM-sync CronJob
    # upserts the Let's Encrypt-issued cert into this same ARN. Without
    # ignore_changes Terraform would re-apply the self-signed material, undoing
    # the trusted chain. The ARN stays stable so the ALB Ingress annotation
    # never needs to change across renewals.
    ignore_changes = [
      private_key,
      certificate_body,
      certificate_chain,
    ]
  }
}

locals {
  # Imported ACM cert ARN bound to both browser-facing ALB HTTPS:443 listeners
  # (ivia-wrp in tier 2 + banking-ui in tier 3). The ACM-sync CronJob in-place
  # upserts a Let's Encrypt cert into THIS SAME ARN so the listener annotation
  # never needs to change. Exported as output.tls_certificate_arn.
  tls_certificate_arn = aws_acm_certificate.workshop_tls.arn
}

#-------------------------------------------------------------------------------
# VPC
#-------------------------------------------------------------------------------

module "vpc" {
  source = "./modules/vpc"

  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  azs          = var.azs
  region       = var.region
  tags         = var.tags
}

#-------------------------------------------------------------------------------
# EKS
# Implicit dependency on vpc via vpc_id + private_subnet_ids inputs.
#-------------------------------------------------------------------------------

module "eks" {
  source = "./modules/eks"

  region              = var.region
  cluster_name        = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  admin_principal_arn = var.admin_principal_arn
  tags                = var.tags
}

#-------------------------------------------------------------------------------
# Bedrock KB AOSS
# Owns AOSS collection + 3 policies + IAM + S3 + corpus. Uses provider aws.kb
# (us-east-1) — Nova 2 Multimodal Embeddings is us-east-1 only.
#
# The KB role trust policy names module.vault_iam.vault_iam_role_arn as a trusted
# principal (the Vault → Bedrock STS assume path). AWS rejects a trust policy
# naming a non-existent principal, so the Vault IAM role MUST be created in this
# same tier — that is why modules/vault_iam (IAM/KMS) stays in tier 1 while the
# Vault server runtime moves to tier 2.
#-------------------------------------------------------------------------------

module "bedrock_kb_aoss" {
  source = "./modules/bedrock_kb_aoss"

  providers = {
    aws  = aws.kb
    time = time
  }

  region              = var.kb_region
  vault_iam_role_arns = [module.vault_iam.vault_iam_role_arn]
  tags                = var.tags
}

#-------------------------------------------------------------------------------
# RDS
# Implicit dependencies via inputs: vpc, audit (workshop_cmk_arn), eks (SGs).
# PostgreSQL 17 + pgaudit.
#-------------------------------------------------------------------------------

module "rds" {
  source = "./modules/rds"

  identifier                = "${var.cluster_name}-pg"
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  cluster_security_group_id = module.eks.cluster_security_group_id
  node_security_group_id    = module.eks.node_security_group_id
  workshop_cmk_arn          = module.audit.workshop_cmk_arn
  instance_class            = var.rds_instance_class
  tags                      = var.tags
}

#-------------------------------------------------------------------------------
# EKS Blueprints Addons
# Standard 4 (vpc-cni, coredns, kube-proxy, eks-pod-identity-agent)
# + aws-ebs-csi-driver + cert-manager + external-dns + AWS Load Balancer
# Controller + Let's Encrypt ClusterIssuer + ACM-sync CronJob. This is the
# cert-issuance machinery the tier-2/tier-3 Ingresses depend on.
#-------------------------------------------------------------------------------

module "addons" {
  source = "./modules/addons"

  region            = var.region
  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn
  tags              = var.tags
  # Plan 03 cert-manager ClusterIssuer consumes acme_email in spec.acme.email.
  # No default per CLAUDE.md identity-defaults rule.
  acme_email = var.acme_email
  # Stable ACM cert ARN: (1) the ACM-sync CronJob IAM policy is scoped to
  # acm:ImportCertificate on THIS ARN only; (2) the CronJob in-place upserts the
  # LE cert into THIS SAME ARN every 6h so the ALB listener annotation never
  # changes across renewals.
  workshop_tls_arn = local.tls_certificate_arn

  depends_on = [module.eks]
}

#-------------------------------------------------------------------------------
# EDR (Uptycs KSPM)
# DaemonSet (k8sosquery) + Deployment (kubequery). Depends ONLY on module.eks.
# Runs in parallel with module.addons so enrollment happens before compliance
# scanners detect non-compliant nodes.
#-------------------------------------------------------------------------------

module "edr" {
  source = "./modules/edr"
  count  = var.enable_edr ? 1 : 0

  cluster_name = module.eks.cluster_name

  depends_on = [module.eks]
}

#-------------------------------------------------------------------------------
# Bedrock KB Index
# Owns opensearch_index + KB + 3 data sources. USES the opensearch provider.
# depends_on bedrock_kb_aoss so the time_sleep IAM-propagation barrier in aoss
# is enforced before the KB is created.
#-------------------------------------------------------------------------------

module "bedrock_kb_index" {
  source = "./modules/bedrock_kb_index"

  providers = {
    aws = aws.kb
  }

  aoss_collection_arn      = module.bedrock_kb_aoss.aoss_collection_arn
  aoss_collection_endpoint = module.bedrock_kb_aoss.aoss_collection_endpoint
  kb_role_arn              = module.bedrock_kb_aoss.kb_role_arn
  embedding_model_arn      = module.bedrock_kb_aoss.embedding_model_arn
  kb_corpus_bucket_arn     = module.bedrock_kb_aoss.kb_corpus_bucket_arn
  kb_multimodal_bucket_arn = module.bedrock_kb_aoss.kb_multimodal_bucket_arn
  kb_multimodal_bucket_id  = module.bedrock_kb_aoss.kb_multimodal_bucket_id
  tags                     = var.tags

  depends_on = [module.bedrock_kb_aoss]
}

#-------------------------------------------------------------------------------
# Vault — IAM / KMS only (tier 1)
# The Vault server runtime (namespace + SA + Helm) is in the tier-2 services
# root (modules/vault_server). This module owns ONLY the KMS unseal key + the
# Pod Identity IAM role + the name-based Pod Identity association — all of which
# must exist in tier 1 because module.bedrock_kb_aoss trusts the role (above)
# and the uc3-logs-writer role trusts it (below). See modules/vault_iam/README.md.
#-------------------------------------------------------------------------------

# Rename shim (module.vault → module.vault_iam): relocates the existing KMS
# unseal key + Pod Identity IAM role state addresses so an in-place apply
# migrates them by address instead of destroy/recreate (a KMS-key recreate
# would schedule the live unseal key for deletion). No-op on a fresh deploy
# where module.vault was never in state.
moved {
  from = module.vault
  to   = module.vault_iam
}

module "vault_iam" {
  source = "./modules/vault_iam"

  cluster_name = module.eks.cluster_name
  tags         = var.tags
}

resource "aws_iam_role_policy" "vault_assume_bedrock" {
  name = "vault-assume-bedrock"
  role = module.vault_iam.vault_iam_role_id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = module.bedrock_kb_aoss.kb_role_arn
    }]
  })
}

#-------------------------------------------------------------------------------
# UC3 CloudWatch logs-writer role (OBJ-2, CONTEXT Delta-6)
# Assumable ONLY by the Vault pod's IAM role. Vault vends short-lived STS creds
# from it (aws/sts/uc3-logs-writer) so the UC3 agent (tier 3) can write the
# ivia_decisions ANCHOR record to /workshop/ivia-decision WITHOUT any standing
# AWS identity. Scoped to logs:PutLogEvents + logs:CreateLogStream on the single
# /workshop/ivia-decision log group only (threat T-071-02, HIGH).
#-------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "uc3_logs_writer" {
  name = "${var.cluster_name}-uc3-logs-writer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { AWS = module.vault_iam.vault_iam_role_arn }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "uc3_logs_writer" {
  name = "uc3-logs-writer-put"
  role = aws_iam_role.uc3_logs_writer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:PutLogEvents", "logs:CreateLogStream"]
      Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/workshop/ivia-decision:*"
    }]
  })
}

resource "aws_iam_role_policy" "vault_assume_uc3_logs" {
  name = "vault-assume-uc3-logs"
  role = module.vault_iam.vault_iam_role_id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = aws_iam_role.uc3_logs_writer.arn
    }]
  })
}

#-------------------------------------------------------------------------------
# Observability (fluent-bit DaemonSet + Firehose + Glue tables)
# Depends on eks (cluster, Pod Identity), addons (IAM infra ready), audit (Glue
# DB + Athena workgroup + workshop CMK), rds (pgaudit log group subscription).
#-------------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"

  region             = var.region
  cluster_name       = module.eks.cluster_name
  glue_database_name = module.audit.glue_database_name
  athena_workgroup   = module.audit.athena_workgroup_name
  kms_key_arn        = module.audit.workshop_cmk_arn
  # PLANE-A pgaudit subscription target. Use the authoritative pre-created log
  # group name from the rds module — NOT a path reconstructed from
  # db_instance_id (which returns db-XXXX, not the DB identifier the real
  # CloudWatch export group uses).
  rds_postgresql_log_group_name = module.rds.postgresql_log_group_name
  tags                          = var.tags

  depends_on = [module.eks, module.addons, module.audit, module.rds]
}
