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
# Wave 2 — Simple AD (LDAP identity source for IVIA user authentication)
# Oscar + Adriana test users provisioned post-deploy by create-simple-ad-users.sh.
# Same VPC as EKS. SG rule allows LDAP from EKS nodes.
#-------------------------------------------------------------------------------

module "simple_ad" {
  source = "./modules/simple_ad"

  region                     = var.region
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id
  admin_password             = var.simple_ad_admin_password
  tags                       = var.tags
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
  simple_ad_dns_ips          = module.simple_ad.dns_ip_addresses
  simple_ad_bind_dn          = module.simple_ad.bind_dn
  simple_ad_admin_password   = var.simple_ad_admin_password
  simple_ad_base_dn          = module.simple_ad.base_dn
  uc2_redirect_uri           = var.uc2_redirect_uri
  ivia_trial_cert            = var.ivia_trial_cert
  ivia_activation_code       = var.ivia_activation_code
  ivia_activated             = var.ivia_activated
  tags                       = var.tags

  depends_on = [time_sleep.alb_webhook_ready, module.simple_ad]
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

  namespace          = "banking-app"
  vault_endpoint     = "http://vault.vault.svc.cluster.local:8200"
  ivia_base_url      = "https://${module.ivia.ivia_service_endpoint}:8436"
  ivia_client_id     = "agent-uc3"
  ivia_client_secret = module.ivia.ivia_client_secret
  # WRP ALB endpoint (no junction prefix) — UC3 agent constructs the full consent
  # URL as: "${ivia_external_url}/isvaop/oauth2/ciba_user_authorize/{auth_req_id}"
  ivia_external_url = module.ivia.ivia_wrp_external_endpoint
  db_host           = module.rds.address
  db_name           = "workshop"
  uc3_agent_image   = var.uc3_agent_image
  bedrock_model_id  = var.bedrock_model_id
  region            = var.region
  rds_cidr          = module.vpc.vpc_cidr
  tags              = var.tags

  depends_on = [module.vault, module.rds, module.ivia, module.uc2_app]
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
  tags               = var.tags

  depends_on = [module.eks, module.addons, module.audit]
}

