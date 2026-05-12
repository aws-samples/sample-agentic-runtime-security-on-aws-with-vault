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
#   Wave 5: vault_config + isva_config  [LOCAL — kubectl port-forward, not in this root module]
#   Wave 6: uc1_agent (vault + rds + bedrock_kb_index + eks)
#   Wave 7: uc2_app (vault + rds + ivia + bedrock_kb_index + eks)
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

  region = var.kb_region
  tags   = var.tags
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

#-------------------------------------------------------------------------------
# ALB Timing Gate (between Wave 3 addons and Wave 4 workloads)
# The ALB webhook must be fully ready before Ingress resources are created.
# 30s sleep after addons module ensures the LBC webhook is registered.
# All Wave 4 modules that create Ingress resources depend on this.
#-------------------------------------------------------------------------------

resource "time_sleep" "alb_webhook_ready" {
  depends_on     = [module.addons]
  create_duration = "30s"
}

#-------------------------------------------------------------------------------
# Wave 4 — IBM Verify Identity Access (IVIA)
# Depends on eks, audit, addons (LBC for ALB), rds, vault (OIDC seam target).
# Deploys IVIA OIDC provider via raw kubernetes_* manifests.
# Gated by time_sleep.alb_webhook_ready (needs LBC webhook ready for Ingress).
#-------------------------------------------------------------------------------

module "ivia" {
  source = "./modules/verify_access"

  # No explicit providers block needed — only default (non-aliased) providers used.

  region                     = var.region
  cluster_name               = module.eks.cluster_name
  rds_endpoint               = module.rds.endpoint
  rds_address                = module.rds.address
  rds_port                   = module.rds.port
  rds_master_username        = module.rds.master_username
  rds_master_user_secret_arn = module.rds.master_user_secret_arn
  rds_db_name                = module.rds.db_name
  vault_endpoint             = module.vault.vault_endpoint
  audit_log_group_names      = module.audit.audit_log_group_names
  addons_ready               = module.addons.aws_load_balancer_controller_release
  icr_entitlement_key        = var.icr_entitlement_key
  tags                       = var.tags

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

  # No explicit providers block needed — only default (non-aliased) providers used.

  vault_addr                 = "http://vault.vault.svc.cluster.local:8200"
  vault_k8s_role             = "uc2"
  vault_jwt_role             = "uc2-jwt"
  vault_db_role              = "uc2-personal-readonly"
  rds_address                = module.rds.address
  rds_port                   = module.rds.port
  rds_db_name                = module.rds.db_name
  rds_cidr                   = module.vpc.vpc_cidr
  knowledge_base_id          = module.bedrock_kb_index.knowledge_base_id
  region                     = var.region
  kb_region                  = var.kb_region
  ui_image                   = var.banking_app_ui_image
  agent_image                = var.banking_app_agent_image
  mcp_image                  = var.banking_app_mcp_image
  bedrock_model_id           = var.bedrock_model_id
  ivia_issuer                = "https://ivia-runtime.ivia.svc.cluster.local"
  ivia_client_id             = "agent-uc2"
  tags                       = var.tags

  depends_on = [time_sleep.alb_webhook_ready]
}
