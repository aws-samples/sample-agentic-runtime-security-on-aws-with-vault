################################################################################
# Root Module — Module Wiring
# Agentic Runtime Security Workshop
# Migrated from Stacks components.tfcomponent.hcl → standard Terraform main.tf
#
# Component dependency graph (now expressed via module input refs + depends_on):
#   Wave 0: audit, vpc                                       (no upstreams)
#   Wave 1: eks (vpc), bedrock_kb_aoss (audit)
#   Wave 2: rds (vpc + audit + eks), addons (eks),
#           bedrock_kb_index (bedrock_kb_aoss)
#   Wave 3: vault (eks + audit + addons)
#   Wave 4: ivia (eks + rds + vault + audit + addons) — gated by time_sleep.alb_webhook_ready
#   Wave 5: vault_config                [LOCAL — kubectl port-forward, not in this root module]
#   Wave 6: uc1_agent (vault + rds + bedrock_kb_index + eks)
#   Wave 7: uc2_app (vault + rds + ivia + bedrock_kb_index + eks)
#   Wave 8: uc3_agent (vault + rds + ivia + uc2_app)
#   Wave 9: observability (eks + addons + audit)
#
# Karpenter and ArgoCD are intentionally OUT of scope for this workshop
# (managed node group only; Helm-direct or plain terraform apply for deploys).
################################################################################

#-------------------------------------------------------------------------------
# Wave 0 — Audit
# Foundation: workshop CMK + 3 pre-created CloudWatch log groups
# (/workshop/vault-audit, /workshop/ivia-decision, /workshop/agent-trace)
# + Glue catalog database 'workshop_logs' + Athena workgroup 'workshop'.
# Locks the W3C traceparent audit-correlation contract before any other
# AWS resource is created.
#-------------------------------------------------------------------------------

module "audit" {
  source = "./modules/audit"

  region               = var.region
  audit_retention_days = var.audit_retention_days
  tags                 = var.tags
}

#-------------------------------------------------------------------------------
# Wave 0 — ECR
# Pre-creates container image repos so build scripts only push (no ad-hoc
# create-repository). force_delete = true for clean terraform destroy.
#-------------------------------------------------------------------------------

module "ecr" {
  source = "./modules/ecr"

  repository_names = ["workshop/uc1-agent", "workshop/uc3-agent", "workshop-banking-app"]
  tags             = var.tags
}

#-------------------------------------------------------------------------------
# Wave 0 — TLS (self-signed bootstrap cert for the browser-facing ALB HTTPS
# listeners; replaced in-place by Phase 07.8 Plan 04 with a Let's Encrypt cert).
#
# This resource MINTS the ACM ARN that both attendee-facing ALB Ingresses
# (IVIA WRP + banking-UI) bind via the `alb.ingress.kubernetes.io/certificate-arn`
# annotation. At first apply the cert content is the self-signed wildcard
# (`*.<region>.elb.amazonaws.com`) below; Phase 07.8 Plan 04's ACM-sync CronJob
# then upserts the LE-issued cert body into THIS SAME ARN via
# `aws acm import-certificate --certificate-arn ...`. The `lifecycle.ignore_changes`
# below (Plan 02) protects that import from being undone by Terraform re-apply.
#
# Phase 07.8 replaces the historical Route53+ACM-DNS-validation path that used
# to mint a separate publicly-trusted cert for an attendee-provided Route53 zone
# (var.wrp_dns_zone_name / var.wrp_public_hostname). That path is RETIRED as
# part of Plan 02 — see Phase 07.8 CONTEXT D-06. Workshop Studio attendees do
# not own a DNS zone; nip.io + Let's Encrypt via cert-manager (Plans 03-04) is
# the only attendee-trusted path going forward.
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
    # Phase 07.8 Plan 02 (D-10): protect the cert body from Terraform drift after
    # Plan 04's ACM-sync CronJob upserts the Let's Encrypt-issued cert into this
    # same ARN. Without ignore_changes Terraform would see the post-import body
    # diverge from tls_self_signed_cert.workshop_tls.cert_pem and re-apply the
    # self-signed material, undoing the trusted chain. The ARN stays stable so
    # the ALB Ingress annotation never needs to change across renewals.
    ignore_changes = [
      private_key,
      certificate_body,
      certificate_chain,
    ]
  }
}

locals {
  # Imported ACM cert ARN bound to both browser-facing ALB HTTPS:443 listeners
  # (banking-ui + ivia-wrp). Phase 07.8 Plan 02 retired the old Route53+ACM-DNS
  # public-FQDN path; Plan 04 in-place upserts a Let's Encrypt-issued cert into
  # THIS SAME ARN so the listener annotation never needs to change.
  tls_certificate_arn = aws_acm_certificate.workshop_tls.arn
}

#-------------------------------------------------------------------------------
# Wave 0 — VPC
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
# Wave 1 — EKS
# Implicit dependency on vpc via vpc_id + private_subnet_ids inputs.
# Does NOT consume audit outputs.
#-------------------------------------------------------------------------------

module "eks" {
  source = "./modules/eks"

  # No explicit providers block needed — only default (non-aliased) providers used.
  # tls/null/cloudinit/time are passed implicitly (terraform-aws-modules/eks wraps them).

  region              = var.region
  cluster_name        = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  admin_principal_arn = var.admin_principal_arn
  tags                = var.tags
}

#-------------------------------------------------------------------------------
# Wave 1 — Bedrock KB AOSS
# Owns AOSS collection + 3 policies + IAM + S3 + corpus.
# Does NOT use the opensearch provider. Outputs the collection endpoint.
# Uses provider aws.kb (us-east-1) — Nova 2 Multimodal Embeddings is
# us-east-1 only; AOSS + S3 corpus must be co-located with the KB.
# No dependency on module.audit — KB creates its own CMK in us-east-1
# (KMS keys are regional; the us-west-2 audit CMK can't be used cross-region).
#-------------------------------------------------------------------------------

module "bedrock_kb_aoss" {
  source = "./modules/bedrock_kb_aoss"

  providers = {
    aws  = aws.kb
    time = time
  }

  region              = var.kb_region
  vault_iam_role_arns = [module.vault.vault_iam_role_arn]
  tags                = var.tags
}

#-------------------------------------------------------------------------------
# Wave 2 — RDS
# Implicit dependencies via inputs: vpc (vpc_id, private_subnet_ids),
# audit (workshop_cmk_arn), eks (cluster_security_group_id).
# PostgreSQL 17 + pgaudit.
#-------------------------------------------------------------------------------

module "rds" {
  source = "./modules/rds"

  # No explicit providers block needed — only default (non-aliased) providers used.

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
# Wave 2 — EKS Blueprints Addons
# Heavy baseline: Standard 4 (vpc-cni, coredns, kube-proxy, eks-pod-identity-agent)
# + aws-ebs-csi-driver + cert-manager + external-dns + AWS Load Balancer Controller.
# Front-loaded into Phase 2 so Phase 3 (Vault/IVIA/agents) can assume these exist.
#-------------------------------------------------------------------------------

module "addons" {
  source = "./modules/addons"

  # No explicit providers block needed — only default (non-aliased) providers used.

  region            = var.region
  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn
  tags              = var.tags
  # Phase 07.8 Plan 01 Task 2: ACME email pass-through. Plan 03 cert-manager
  # ClusterIssuer (new resource added there) consumes module.addons.acme_email
  # in spec.acme.email. No default per CLAUDE.md identity-defaults rule.
  acme_email = var.acme_email
  # Phase 07.8 Plan 03: stable ACM cert ARN pass-through. The addons module
  # uses this in two places: (1) the ACM-sync CronJob's IAM policy is scoped
  # to acm:ImportCertificate on THIS resource ARN only (single-resource IAM
  # scope; STRIDE T-cronjob-iam-overprivilege mitigation, NOT wildcard); (2)
  # the CronJob in-place upserts the Let's Encrypt cert content into THIS
  # SAME ARN every 6h so the ALB listener annotation never changes across
  # cert-manager-driven renewals (D-03 stable-ARN contract). Drift on the
  # ARN's cert body is suppressed by lifecycle.ignore_changes set by Plan 02.
  workshop_tls_arn = local.tls_certificate_arn

  depends_on = [module.eks]
}

#-------------------------------------------------------------------------------
# Wave 1.5 — EDR (Uptycs KSPM)
# DaemonSet (k8sosquery) on every node for host/container telemetry + Protect.
# Deployment (kubequery) for Kubernetes API telemetry + compliance scanning.
# Depends ONLY on module.eks (needs cluster + vpc-cni + coredns from
# cluster_addons — both deploy before nodes ready). Runs in parallel with
# module.addons so Uptycs enrollment happens BEFORE compliance scanners
# (e.g. Wiz) detect non-compliant nodes and terminate them.
#-------------------------------------------------------------------------------

module "edr" {
  source = "./modules/edr"
  count  = var.enable_edr ? 1 : 0

  cluster_name = module.eks.cluster_name

  depends_on = [module.eks]
}

#-------------------------------------------------------------------------------
# Wave 2 — Bedrock KB Index
# Owns opensearch_index + KB + 3 data sources. USES the opensearch provider.
# depends_on bedrock_kb_aoss so the time_sleep IAM-propagation barrier in
# aoss is enforced before the KB is created.
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
# Wave 3 — Vault
# Depends on eks (cluster creds), audit (CMK, log groups), addons (cert-manager).
# Deploys Vault via Helm chart in Raft 3-node HA with dedicated KMS auto-unseal
# key + Pod Identity for unseal IAM.
#-------------------------------------------------------------------------------

module "vault" {
  source = "./modules/vault"

  # No explicit providers block needed — only default (non-aliased) providers used.

  region                             = var.region
  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  oidc_provider_arn                  = module.eks.oidc_provider_arn
  addons_ready                       = module.addons.aws_load_balancer_controller_release
  audit_log_group_names              = module.audit.audit_log_group_names
  tags                               = var.tags

  depends_on = [module.addons]
}

resource "aws_iam_role_policy" "vault_assume_bedrock" {
  name = "vault-assume-bedrock"
  role = module.vault.vault_iam_role_id
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
# Assumable ONLY by the Vault Helm pod's IAM role. Vault vends short-lived STS
# creds from it (aws/sts/uc3-logs-writer) so the UC3 agent can write the
# ivia_decisions ANCHOR record to /workshop/ivia-decision WITHOUT any standing
# AWS identity on the agent's service account. Scoped to logs:PutLogEvents +
# logs:CreateLogStream on the single /workshop/ivia-decision log group only —
# never the wildcard form (threat T-071-02, HIGH). Region + account interpolated;
# no literal region (canonical region contract).
#-------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "uc3_logs_writer" {
  name = "${var.cluster_name}-uc3-logs-writer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { AWS = module.vault.vault_iam_role_arn }
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
  role = module.vault.vault_iam_role_id
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
# ALB Timing Gate (between Wave 3 addons and Wave 4 workloads)
# The ALB webhook must be fully ready before Ingress resources are created.
# 30s sleep after addons module ensures the LBC webhook is registered.
# All Wave 4 modules that create Ingress resources depend on this.
#-------------------------------------------------------------------------------

resource "time_sleep" "alb_webhook_ready" {
  depends_on      = [module.addons]
  create_duration = "30s"
}

#-------------------------------------------------------------------------------
# Wave 4 — IBM Verify Identity Access (IVIA)
# Depends on eks, audit, addons (LBC for ALB), rds, vault (OIDC seam target).
# Deploys IVIA OIDC provider via raw kubernetes_* manifests.
# Gated by time_sleep.alb_webhook_ready (needs LBC webhook ready for Ingress).
# COMMENTED OUT — architecture under review (3-container pod vs standard).
#-------------------------------------------------------------------------------

module "ivia" {
  source = "./modules/verify_access"

  region                       = var.region
  cluster_name                 = module.eks.cluster_name
  icr_entitlement_key          = var.icr_entitlement_key
  ivia_mmfa_push_client_secret = var.ivia_mmfa_push_client_secret
  node_security_group_id       = module.eks.node_security_group_id
  tls_certificate_arn          = local.tls_certificate_arn
  tags                         = var.tags

  depends_on = [time_sleep.alb_webhook_ready]
}

#-------------------------------------------------------------------------------
# Wave 6 — Use Case 1 Agent
# Deploys the agentic security agent pod that integrates Vault, IVIA, RDS,
# and Bedrock KB for runtime identity-aware authorization.
# Vault addr and role are hardcoded — vault_config runs locally, not here.
# Gated by time_sleep.alb_webhook_ready (if UC1 creates Ingress resources).
#-------------------------------------------------------------------------------

module "uc1_agent" {
  source = "./modules/uc1_agent"

  # No explicit providers block needed — only default (non-aliased) providers used.

  vault_addr        = "http://vault.vault.svc.cluster.local:8200"
  vault_role        = "uc1"
  rds_address       = module.rds.address
  rds_port          = module.rds.port
  rds_db_name       = module.rds.db_name
  knowledge_base_id = module.bedrock_kb_index.knowledge_base_id
  region            = var.region
  kb_region         = var.kb_region
  agent_image       = var.uc1_agent_image
  bedrock_model_id  = var.bedrock_model_id
  tags              = var.tags

  depends_on = [time_sleep.alb_webhook_ready]
}

#-------------------------------------------------------------------------------
# Wave 7 — Use Case 2 Banking App
# Deploys the UC2 personalized banking app: SvelteKit UI + Strands agent +
# MCP server. Three pods in banking-app namespace with default-deny
# NetworkPolicy + per-pod egress rules.
# UC3 extends this deployment (adds CIBA client + write Vault role, same namespace).
# Gated by time_sleep.alb_webhook_ready (has ALB Ingress resources).
#-------------------------------------------------------------------------------

module "uc2_app" {
  source = "./modules/uc2_agent"

  vault_addr            = "http://vault.vault.svc.cluster.local:8200"
  vault_k8s_role        = "uc2-agent"
  vault_jwt_role        = "uc2-jwt"
  vault_db_role         = "uc2-personal-readonly"
  rds_address           = module.rds.address
  rds_port              = module.rds.port
  rds_db_name           = module.rds.db_name
  rds_cidr              = module.vpc.vpc_cidr
  knowledge_base_id     = module.bedrock_kb_index.knowledge_base_id
  region                = var.region
  kb_region             = var.kb_region
  ui_image              = var.banking_app_ui_image
  agent_image           = var.banking_app_agent_image
  mcp_image             = var.banking_app_mcp_image
  bedrock_model_id      = var.bedrock_model_id
  ivia_ingress_hostname = module.ivia.ivia_ingress_hostname
  ivia_service_endpoint = module.ivia.ivia_service_endpoint
  ivia_client_id        = "agent-uc2"
  ivia_client_secret    = module.ivia.ivia_client_secret
  tls_certificate_arn   = local.tls_certificate_arn
  ivia_public_issuer    = "https://${module.ivia.ivia_ingress_hostname}"
  ivia_oidc_ca_pem      = module.ivia.ivia_oidc_ca_pem
  tags                  = var.tags

  depends_on = [time_sleep.alb_webhook_ready]
}

#-------------------------------------------------------------------------------
# Wave 8 — Use Case 3 Agent (privileged refund writer)
# UC3 agent joins banking-app namespace; CIBA + token exchange + refund write.
# Depends on vault (k8s auth + secret backend), rds (write creds), ivia (CIBA
# authorization endpoint), and uc2_app (banking-app namespace must exist first).
#-------------------------------------------------------------------------------

module "uc3_agent" {
  source = "./modules/uc3_agent"

  namespace              = "banking-app"
  vault_endpoint         = "http://vault.vault.svc.cluster.local:8200"
  ivia_base_url          = "https://${module.ivia.ivia_service_endpoint}:8436"
  ivia_client_id         = "agent-uc3"
  ivia_id_token_audience = "agent-uc2"
  ivia_client_secret     = module.ivia.ivia_client_secret
  ivia_external_url      = "https://${module.ivia.ivia_ingress_hostname}"
  db_host                = module.rds.address
  db_name                = "workshop"
  uc3_agent_image        = var.uc3_agent_image
  bedrock_model_id       = var.bedrock_model_id
  region                 = var.region
  rds_cidr               = module.vpc.vpc_cidr
  ivia_oidc_ca_pem       = module.ivia.ivia_oidc_ca_pem
  ivia_runtime_url       = "https://iviaruntime.${module.ivia.namespace}.svc.cluster.local:9443"
  ivia_scim_user         = module.ivia.ivia_runtime_user
  ivia_scim_password     = module.ivia.ivia_runtime_user_password
  ivia_runtime_ca_pem    = module.ivia.ivia_runtime_ca_pem
  ivia_namespace         = module.ivia.namespace
  tags                   = var.tags

  depends_on = [module.vault, module.rds, module.ivia, module.uc2_app]
}

#-------------------------------------------------------------------------------
# iviaop-config issuer + redirect_uri injection — Path A (deferred patch)
#
# Two values in the iviaop-config ConfigMap can only be known after the ALBs
# exist, and both depend on raw ALB hostnames that the AWS Load Balancer
# Controller assigns post-apply:
#   - provider.yml  issuer/base_url  → the ivia-wrp (login) ALB hostname
#   - clients.yml   agent-uc2 redirect_uri → the banking-ui ALB hostname
#
# module.uc2_app already consumes module.ivia outputs, so module.ivia cannot
# read back from module.uc2_app (TF rejects the cycle). And inside module.ivia
# the iviaop-config ConfigMap is created before its own Ingress reconciles, so
# the login ALB hostname isn't available there either.
#
# Resolution: module.ivia ships provider.yml + clients.yml with placeholder
# hostnames. After module.ivia and module.uc2_app complete (ALB hostnames now
# known), this root-level patch overwrites just those two ConfigMap keys with
# the real ALB hostnames, then rolls the iviaop Deployment so it reloads them
# at startup. agent-uc1/agent-uc3 entries are unaffected.
#-------------------------------------------------------------------------------

locals {
  # Browser-facing https issuer = the ivia-wrp (login) ALB; redirect_uri host =
  # the banking-ui ALB. Both ALB hostnames are real post-apply values
  # (wait_for_load_balancer = true on each Ingress).
  ivia_public_issuer = "https://${module.ivia.ivia_ingress_hostname}"
  uc2_redirect_uri   = "https://${module.uc2_app.banking_ui_alb_hostname}/callback"

  iviaop_provider_yml_resolved = templatefile(
    "${path.module}/modules/verify_access/iviaop-config/provider.yml.tftpl",
    {
      ivia_public_url    = "${local.ivia_public_issuer}/isvaop"
      ivia_public_issuer = local.ivia_public_issuer
    }
  )

  iviaop_clients_yml_resolved = templatefile(
    "${path.module}/modules/verify_access/iviaop-config/clients.yml.tftpl",
    {
      ivia_client_secret = module.ivia.ivia_client_secret
      uc2_redirect_uri   = local.uc2_redirect_uri
    }
  )
}

resource "kubernetes_config_map_v1_data" "iviaop_clients_patch" {
  metadata {
    name      = "iviaop-config"
    namespace = "verify-access"
  }

  data = {
    "provider.yml" = local.iviaop_provider_yml_resolved
    "clients.yml"  = local.iviaop_clients_yml_resolved
  }

  field_manager = "root-tf-clients-patch"
  force         = true

  depends_on = [module.ivia, module.uc2_app]
}

# Roll the iviaop Deployment whenever the resolved provider.yml or clients.yml
# changes. The iviaop pod loads both files only at startup; without a restart
# the patched ConfigMap would sit on disk unread.
resource "null_resource" "iviaop_rollout_restart" {
  triggers = {
    iviaop_config_sha256 = sha256("${local.iviaop_provider_yml_resolved}${local.iviaop_clients_yml_resolved}")
  }

  # Point kubectl at this cluster first — during `terraform apply` the attendee's
  # kubeconfig has not been configured yet (configure-workshop.sh runs post-apply),
  # so a bare `kubectl` cannot resolve the API endpoint. update-kubeconfig is
  # idempotent and derives cluster name/region from module outputs (no literals).
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} && kubectl rollout restart deploy/iviaop -n verify-access && kubectl rollout status deploy/iviaop -n verify-access --timeout=180s"
  }

  depends_on = [kubernetes_config_map_v1_data.iviaop_clients_patch]
}

#-------------------------------------------------------------------------------
# Wave 9 — Observability (fluent-bit DaemonSet + Firehose + Glue tables)
# Deployed after UC3 to capture agent logs from all three planes.
# Depends on eks (cluster, Pod Identity), addons (IAM infra ready),
# and audit (Glue DB + Athena workgroup + workshop CMK).
#-------------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"

  region             = var.region
  cluster_name       = module.eks.cluster_name
  log_bucket_name    = "${module.eks.cluster_name}-workshop-logs"
  glue_database_name = module.audit.glue_database_name
  athena_workgroup   = module.audit.athena_workgroup_name
  kms_key_arn        = module.audit.workshop_cmk_arn
  # PLANE-A pgaudit subscription target. Use the authoritative pre-created log
  # group name from the rds module (aws_cloudwatch_log_group.rds_postgresql) —
  # NOT a path reconstructed from db_instance_id. db_instance_id returns the RDS
  # resource ID (db-XXXX), but the real CloudWatch export group uses the DB
  # *identifier* (/aws/rds/instance/agenticlife-pg/postgresql), so reconstructing
  # from the resource ID points at a non-existent group (ResourceNotFoundException).
  rds_postgresql_log_group_name = module.rds.postgresql_log_group_name
  tags                          = var.tags

  depends_on = [module.eks, module.addons, module.audit, module.rds]
}

