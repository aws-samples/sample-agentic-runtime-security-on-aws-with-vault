################################################################################
# Component Definitions
# Agentic Runtime Security Workshop — Phase 2 Foundation + Phase 3 Platform
#                                   + Phase 4 Use Case 1 Agent
# Single-region stack (canonical region locked in deployments.tfdeploy.hcl):
# audit foundation + VPC + EKS + addons + RDS + Bedrock KB + Vault + IVIA
# + vault_config + isva_config + uc1_agent
# Reference: ~/git-repos/eks-terraform-stacks/infrastructure/components.tfcomponent.hcl
#
# Component dependency graph (resolved automatically by Stacks via input refs):
#   Wave 0: audit, vpc                                       (no upstreams)
#   Wave 1: eks (vpc), bedrock_kb_aoss (audit)
#   Wave 2: rds (vpc + audit + eks), addons (eks),
#           bedrock_kb_index (bedrock_kb_aoss)
#   Wave 3: vault (eks + audit + addons)
#   Wave 4: ivia (eks + rds + vault + audit + addons)
#   Wave 5: vault_config (vault + eks + rds + ivia),
#           isva_config  (ivia + vault_config)
#   Wave 6: uc1_agent (vault_config + rds + bedrock_kb_index + eks)
#
# Per HCP Stacks docs, component output references in `inputs` are sufficient
# to express ordering; explicit `depends_on` is reserved for non-obvious
# barriers (e.g. the IAM-propagation `time_sleep` between bedrock_kb_aoss
# and bedrock_kb_index, which is otherwise transparent to the dataflow).
#
# Karpenter and ArgoCD are intentionally OUT of scope for this workshop
# (managed node group only; Helm-direct or Stacks for app deployments).
################################################################################

#-------------------------------------------------------------------------------
# Audit Component (Wave 0)
# Foundation: workshop CMK + 3 pre-created CloudWatch log groups
# (/workshop/vault-audit, /workshop/ivia-decision, /workshop/agent-trace)
# + Glue catalog database 'workshop_logs' + Athena workgroup 'workshop'.
# Locks the W3C traceparent audit-correlation contract before any other
# AWS resource is created. THE load-bearing Phase 2 deliverable.
#-------------------------------------------------------------------------------

component "audit" {
  source = "./modules/audit"

  providers = {
    aws = provider.aws.main
  }

  inputs = {
    region               = var.region
    audit_retention_days = var.audit_retention_days
    tags                 = var.tags
  }
}

#-------------------------------------------------------------------------------
# VPC Component (Wave 0)
#-------------------------------------------------------------------------------

component "vpc" {
  source = "./modules/vpc"

  providers = {
    aws = provider.aws.main
  }

  inputs = {
    cluster_name = var.cluster_name
    vpc_cidr     = var.vpc_cidr
    azs          = var.azs
    region       = var.region
    tags         = var.tags
  }
}

#-------------------------------------------------------------------------------
# EKS Component (Wave 1)
# Implicit dependency on vpc via vpc_id + private_subnet_ids inputs below.
# Does NOT consume audit outputs — no audit dependency.
#-------------------------------------------------------------------------------

component "eks" {
  source = "./modules/eks"

  providers = {
    aws       = provider.aws.main
    tls       = provider.tls.main
    null      = provider.null.main
    cloudinit = provider.cloudinit.main
    time      = provider.time.main
  }

  inputs = {
    region              = var.region
    cluster_name        = var.cluster_name
    vpc_id              = component.vpc.vpc_id
    private_subnet_ids  = component.vpc.private_subnet_ids
    admin_principal_arn = var.admin_principal_arn
    tags                = var.tags
  }
}

#-------------------------------------------------------------------------------
# RDS Component (Wave 2 — depends on eks for cluster_security_group_id)
# Implicit dependencies via inputs: vpc (vpc_id, private_subnet_ids),
# audit (workshop_cmk_arn), eks (cluster_security_group_id).
# PostgreSQL 17 + pgaudit (enabled in Phase 2 to avoid parameter-group reboot churn later).
#-------------------------------------------------------------------------------

component "rds" {
  source = "./modules/rds"

  providers = {
    aws    = provider.aws.main
    random = provider.random.main
  }

  inputs = {
    identifier                = "${var.cluster_name}-pg"
    vpc_id                    = component.vpc.vpc_id
    private_subnet_ids        = component.vpc.private_subnet_ids
    cluster_security_group_id = component.eks.cluster_security_group_id
    workshop_cmk_arn          = component.audit.workshop_cmk_arn
    instance_class            = var.rds_instance_class
    tags                      = var.tags
  }
}

#-------------------------------------------------------------------------------
# Bedrock Knowledge Base — split into two components to avoid a circular
# dependency: the Stack-level opensearch provider's URL must reference the
# AOSS collection endpoint, and the bedrock_kb component would itself USE
# that opensearch provider — Stacks rejects the resulting cycle.
#
# Split:
#   bedrock_kb_aoss  — owns AOSS collection + 3 policies + IAM + S3 + corpus.
#                      Does NOT use the opensearch provider. Outputs the
#                      collection endpoint that the opensearch provider reads.
#   bedrock_kb_index — owns opensearch_index + KB + 3 data sources. USES the
#                      opensearch provider. depends_on bedrock_kb_aoss so
#                      the time_sleep IAM-propagation barrier in aoss is
#                      enforced before the KB is created.
#-------------------------------------------------------------------------------

component "bedrock_kb_aoss" {
  source = "./modules/bedrock_kb_aoss"

  # Uses provider.aws.kb (us-east-1) — Nova 2 Multimodal Embeddings is
  # us-east-1 only; AOSS + S3 corpus must be co-located with the KB.
  # No dependency on component.audit — KB creates its own CMK in us-east-1
  # (KMS keys are regional; the us-west-2 audit CMK can't be used cross-region).

  providers = {
    aws  = provider.aws.kb
    time = provider.time.main
  }

  inputs = {
    region = var.kb_region
    tags   = var.tags
  }
}

component "bedrock_kb_index" {
  source = "./modules/bedrock_kb_index"

  depends_on = [component.bedrock_kb_aoss]

  providers = {
    aws = provider.aws.kb
  }

  inputs = {
    aoss_collection_arn      = component.bedrock_kb_aoss.aoss_collection_arn
    aoss_collection_endpoint = component.bedrock_kb_aoss.aoss_collection_endpoint
    kb_role_arn              = component.bedrock_kb_aoss.kb_role_arn
    embedding_model_arn      = component.bedrock_kb_aoss.embedding_model_arn
    kb_corpus_bucket_arn     = component.bedrock_kb_aoss.kb_corpus_bucket_arn
    kb_multimodal_bucket_arn = component.bedrock_kb_aoss.kb_multimodal_bucket_arn
    kb_multimodal_bucket_id  = component.bedrock_kb_aoss.kb_multimodal_bucket_id
    tags                     = var.tags
  }
}

#-------------------------------------------------------------------------------
# EKS Blueprints Addons Component (Wave 2)
# Heavy baseline per CONTEXT.md user override:
#   Standard 4 (vpc-cni, coredns, kube-proxy, eks-pod-identity-agent)
#   + aws-ebs-csi-driver
#   + cert-manager
#   + external-dns
#   + AWS Load Balancer Controller
# Front-loaded into Phase 2 so Phase 3 (Vault/IVIA/agents) can assume these exist.
#-------------------------------------------------------------------------------

component "addons" {
  source = "./modules/addons"

  # Implicit dependency on component.eks via cluster_endpoint, cluster_version,
  # oidc_provider_arn inputs below.

  providers = {
    aws        = provider.aws.main
    helm       = provider.helm.main
    kubernetes = provider.kubernetes.main
    time       = provider.time.main
    random     = provider.random.main
  }

  inputs = {
    region            = var.region
    cluster_name      = component.eks.cluster_name
    cluster_endpoint  = component.eks.cluster_endpoint
    cluster_version   = component.eks.cluster_version
    oidc_provider_arn = component.eks.oidc_provider_arn
    tags              = var.tags
  }
}

#-------------------------------------------------------------------------------
# Vault Component (Wave 3)
# Depends on eks (cluster creds), audit (CMK, log groups), addons (cert-manager).
# Deploys Vault 2.0.0 via Helm chart 0.32.0 in Raft 3-node HA with
# dedicated KMS auto-unseal key + Pod Identity for unseal IAM.
#-------------------------------------------------------------------------------
component "vault" {
  source = "./modules/vault"

  providers = {
    aws        = provider.aws.main
    helm       = provider.helm.main
    kubernetes = provider.kubernetes.main
  }

  inputs = {
    region                             = var.region
    cluster_name                       = component.eks.cluster_name
    cluster_endpoint                   = component.eks.cluster_endpoint
    cluster_certificate_authority_data = component.eks.cluster_certificate_authority_data
    oidc_provider_arn                  = component.eks.oidc_provider_arn
    addons_ready                       = component.addons.aws_load_balancer_controller_release
    audit_log_group_names              = component.audit.audit_log_group_names
    tags                               = var.tags
  }
}

#-------------------------------------------------------------------------------
# IBM Verify Identity Access Component (Wave 4)
# Depends on eks (cluster creds), audit (log groups), addons (LBC for ALB),
# rds (PostgreSQL backend), vault (OIDC seam target).
# Deploys IVIA 11.0.2 OIDC provider via raw kubernetes_* manifests.
# Pitfall 8: RDS output names use NO prefix — component.rds.endpoint,
#            component.rds.address, etc. (NOT component.rds.rds_endpoint).
#-------------------------------------------------------------------------------
component "ivia" {
  source = "./modules/verify_access"

  providers = {
    aws        = provider.aws.main
    kubernetes = provider.kubernetes.main
    random     = provider.random.main
    time       = provider.time.main
  }

  inputs = {
    region                     = var.region
    cluster_name               = component.eks.cluster_name
    rds_endpoint               = component.rds.endpoint
    rds_address                = component.rds.address
    rds_port                   = component.rds.port
    rds_master_username        = component.rds.master_username
    rds_master_user_secret_arn = component.rds.master_user_secret_arn
    rds_db_name                = component.rds.db_name
    vault_endpoint             = component.vault.vault_endpoint
    audit_log_group_names      = component.audit.audit_log_group_names
    addons_ready               = component.addons.aws_load_balancer_controller_release
    icr_entitlement_key        = var.icr_entitlement_key
    tags                       = var.tags
  }
}

#-------------------------------------------------------------------------------
# Vault Config Component (Wave 5)
# Configures Vault backends after Vault is running:
#   - Kubernetes auth (CONF-01), JWT auth (CONF-02), PostgreSQL secrets engine
#     (CONF-03), AWS secrets engine (CONF-04), audit device (PLAT-05).
# RDS password is NOT a plain stack variable — vault_config fetches it from
# Secrets Manager via rds_master_user_secret_arn + data.aws_secretsmanager_secret_version.
# Pitfall 8: RDS output names use NO prefix — component.rds.endpoint,
#            component.rds.master_username, etc. (NOT component.rds.rds_endpoint).
#-------------------------------------------------------------------------------
component "vault_config" {
  source = "./modules/vault_config"

  providers = {
    vault = provider.vault.main
    aws   = provider.aws.main
  }

  inputs = {
    region                             = var.region
    cluster_endpoint                   = component.eks.cluster_endpoint
    cluster_certificate_authority_data = component.eks.cluster_certificate_authority_data
    cluster_oidc_issuer                = component.eks.cluster_oidc_issuer
    ivia_oidc_discovery_url            = component.ivia.ivia_oidc_discovery_url
    rds_endpoint                       = component.rds.endpoint
    rds_master_username                = component.rds.master_username
    rds_master_user_secret_arn         = component.rds.master_user_secret_arn
    rds_db_name                        = component.rds.db_name
    bedrock_role_arn                   = component.bedrock_kb_aoss.kb_role_arn
    tags                               = var.tags
  }
}

#-------------------------------------------------------------------------------
# IVIA Config Component (Wave 5 — after vault_config)
# Registers OAuth clients, CIBA policy, RAR types, and JWT signing key in IVIA
# via the restapi provider against the IVIA Config Service REST API.
# explicit depends_on on vault_config ensures Vault JWT auth is configured
# before IVIA OAuth clients are registered (IVIA validates against Vault JWKS
# during client registration in some policy configurations).
#-------------------------------------------------------------------------------
component "isva_config" {
  source = "./modules/isva_config"

  depends_on = [component.vault_config]

  providers = {
    restapi = provider.restapi.main
  }

  inputs = {
    ivia_service_endpoint      = component.ivia.ivia_service_endpoint
    vault_config_jwt_auth_path = component.vault_config.jwt_auth_path
    ivia_admin_username        = var.ivia_admin_username
    ivia_admin_password        = var.ivia_admin_password
  }
}

#-------------------------------------------------------------------------------
# UC1 Agent Component (Wave 6)
# Non-personalized read-only Strands agent. Authenticates to Vault via
# Kubernetes auth (SA JWT), receives JIT Postgres + Bedrock STS credentials.
# Implicit ordering via vault_config, rds, bedrock_kb_index, eks inputs.
#-------------------------------------------------------------------------------
component "uc1_agent" {
  source = "./modules/uc1_agent"

  providers = {
    kubernetes = provider.kubernetes.main
  }

  inputs = {
    vault_addr        = component.vault.vault_endpoint
    vault_role        = component.vault_config.uc1_role_name
    rds_address       = component.rds.address
    rds_port          = component.rds.port
    rds_db_name       = component.rds.db_name
    knowledge_base_id = component.bedrock_kb_index.knowledge_base_id
    region            = var.region
    kb_region         = var.kb_region
    agent_image       = var.uc1_agent_image
    bedrock_model_id  = var.bedrock_model_id
    tags              = var.tags
  }
}
