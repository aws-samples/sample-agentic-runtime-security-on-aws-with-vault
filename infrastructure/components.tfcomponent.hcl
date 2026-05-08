################################################################################
# Component Definitions
# Agentic Runtime Security Workshop — Phase 2 Foundation
# Single-region stack (canonical region locked in deployments.tfdeploy.hcl):
# audit foundation + VPC + EKS + addons + RDS + Bedrock KB
# Reference: ~/git-repos/eks-terraform-stacks/infrastructure/components.tfcomponent.hcl
#
# Component dependency graph (resolved automatically by Stacks via input refs):
#   Wave 0: audit, vpc                                       (no upstreams)
#   Wave 1: eks (vpc), bedrock_kb_aoss (audit)
#   Wave 2: rds (vpc + audit + eks), addons (eks),
#           bedrock_kb_index (bedrock_kb_aoss)
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

# --- KB components removed for region migration (us-west-2 → us-east-1).
# --- `removed` blocks tell Stacks to destroy the us-west-2 state.
# --- Replace with component blocks pointing to provider.aws.kb in step 2.

removed {
  source = "./modules/bedrock_kb_aoss"
  from   = component.bedrock_kb_aoss

  providers = {
    aws  = provider.aws.main
    time = provider.time.main
  }
}

removed {
  source = "./modules/bedrock_kb_index"
  from   = component.bedrock_kb_index

  providers = {
    aws = provider.aws.main
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
