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
# Wave 0 — DNS + TLS (AWS-native: Route53 + ACM public cert)
# Owns a Route53 public hosted zone for a delegated workshop subdomain plus a
# wildcard ACM cert used by the browser-facing ALB HTTPS listeners (banking-ui
# + ivia-wrp). Independent of all other resources; only the NS delegation at the
# parent domain (manual, one-time) gates ACM validation. NOT Vault PKI.
#-------------------------------------------------------------------------------

module "dns" {
  source = "./modules/dns"

  domain_name = var.workshop_domain
  tags        = var.tags
}

locals {
  # Browser-facing HTTPS hostnames under the delegated workshop subdomain.
  # banking-ui (app + OAuth /callback) and IVIA/WRP (login/authorize/consent).
  bank_hostname  = "bank.${var.workshop_domain}"
  login_hostname = "login.${var.workshop_domain}"
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
# COMMENTED OUT — may not be needed; IVIA architecture under review.
#-------------------------------------------------------------------------------

# module "simple_ad" {
#   source = "./modules/simple_ad"
#
#   region                     = var.region
#   vpc_id                     = module.vpc.vpc_id
#   private_subnet_ids         = module.vpc.private_subnet_ids
#   eks_node_security_group_id = module.eks.node_security_group_id
#   admin_password             = var.simple_ad_admin_password
#   tags                       = var.tags
# }

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
# COMMENTED OUT — architecture under review (3-container pod vs standard).
#-------------------------------------------------------------------------------

module "ivia" {
  source = "./modules/verify_access"

  region                 = var.region
  cluster_name           = module.eks.cluster_name
  icr_entitlement_key    = var.icr_entitlement_key
  node_security_group_id = module.eks.node_security_group_id
  tls_certificate_arn    = module.dns.certificate_arn
  public_hostname        = local.login_hostname
  tags                   = var.tags

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
  tls_certificate_arn   = module.dns.certificate_arn
  public_hostname       = local.bank_hostname
  ivia_public_issuer    = "https://${local.login_hostname}"
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
  ivia_external_url  = "https://${local.login_hostname}"
  db_host            = module.rds.address
  db_name            = "workshop"
  uc3_agent_image    = var.uc3_agent_image
  bedrock_model_id   = var.bedrock_model_id
  region             = var.region
  rds_cidr           = module.vpc.vpc_cidr
  tags               = var.tags

  depends_on = [module.vault, module.rds, module.ivia, module.uc2_app]
}

#-------------------------------------------------------------------------------
# agent-uc2 redirect_uri injection — Path A
#
# Why this exists: agent-uc2's redirect_uri must contain the banking-ui ALB
# hostname, which only exists after module.uc2_app deploys the Ingress.
# module.uc2_app already depends on module.ivia outputs (ivia_client_secret,
# ivia_service_endpoint, ivia_ingress_hostname), so module.ivia cannot in turn
# read from module.uc2_app — TF would reject the cycle.
#
# Resolution: module.ivia ships clients.yml with a placeholder redirect for
# agent-uc2 (`http://placeholder.invalid/callback`). After both modules
# complete, this root-level resource pair overwrites just the clients.yml
# key in the iviaop-config ConfigMap with the real ALB hostname, then triggers
# a rollout-restart of the iviaop Deployment so the new clients.yml is loaded
# at startup. agent-uc1 and agent-uc3 remain unaffected (their entries in
# clients.yml don't contain the templated hostname).
#-------------------------------------------------------------------------------

locals {
  uc2_redirect_uri = "https://${local.bank_hostname}/callback"

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
    "clients.yml" = local.iviaop_clients_yml_resolved
  }

  field_manager = "root-tf-clients-patch"
  force         = true

  depends_on = [module.ivia, module.uc2_app]
}

# Roll the iviaop Deployment whenever the resolved clients.yml changes. The
# iviaop pod loads clients.yml only at startup; without a restart the patched
# ConfigMap would sit on disk unread.
resource "null_resource" "iviaop_rollout_restart" {
  triggers = {
    clients_yml_sha256 = sha256(local.iviaop_clients_yml_resolved)
  }

  provisioner "local-exec" {
    command = "kubectl rollout restart deploy/iviaop -n verify-access && kubectl rollout status deploy/iviaop -n verify-access --timeout=180s"
  }

  depends_on = [kubernetes_config_map_v1_data.iviaop_clients_patch]
}

#-------------------------------------------------------------------------------
# Workshop DNS records — point the stable HTTPS hostnames at the two browser-
# facing ALBs (created by the AWS Load Balancer Controller from each Ingress).
# CNAME (not ALIAS) is sufficient for these subdomains and avoids an aws_lb
# zone-id lookup. The wildcard ACM cert on each ALB matches both names.
#-------------------------------------------------------------------------------

resource "aws_route53_record" "bank" {
  zone_id = module.dns.zone_id
  name    = local.bank_hostname
  type    = "CNAME"
  ttl     = 300
  records = [module.uc2_app.banking_ui_alb_hostname]
}

resource "aws_route53_record" "login" {
  zone_id = module.dns.zone_id
  name    = local.login_hostname
  type    = "CNAME"
  ttl     = 300
  records = [module.ivia.ivia_wrp_alb_hostname]
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

