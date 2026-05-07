################################################################################
# Component Definitions
# Agentic Runtime Security Workshop — Phase 2 Foundation
# Single-region stack (canonical region locked in deployments.tfdeploy.hcl):
# audit foundation + VPC + EKS + addons + RDS + Bedrock KB
# Reference: ~/git-repos/eks-terraform-stacks/infrastructure/components.tfcomponent.hcl
#
# Component dependency graph (waves):
#   Wave 0: audit, vpc          (no dependencies; parallel)
#   Wave 1: eks (vpc, audit), rds (vpc, audit), bedrock_kb (audit)
#   Wave 2: addons (eks)
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
# Depends on vpc (subnets) and audit (workshop CMK arn for any CMK-encrypted log groups).
#-------------------------------------------------------------------------------

component "eks" {
  source = "./modules/eks"

  depends_on = [component.vpc, component.audit]

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
# RDS Component (Wave 1)
# Depends on vpc (db subnet group) and audit (workshop CMK for storage encryption).
# PostgreSQL 17 + pgaudit (enabled in Phase 2 to avoid parameter-group reboot churn later).
#-------------------------------------------------------------------------------

component "rds" {
  source = "./modules/rds"

  # Implicit dependency on component.eks via cluster_security_group_id input.
  depends_on = [component.vpc, component.audit, component.eks]

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
# Bedrock Knowledge Base Component (Wave 1)
# Depends on audit (workshop CMK for AOSS + S3 corpus encryption).
# AOSS collection + 3 security/access policies + opensearch_index + KB + 3 data sources
# (HR handbook + customer records + finance Q&A — multi-domain synthetic corpus).
#-------------------------------------------------------------------------------

component "bedrock_kb" {
  source = "./modules/bedrock_kb"

  depends_on = [component.audit]

  providers = {
    aws        = provider.aws.main
    opensearch = provider.opensearch.main
    time       = provider.time.main
  }

  inputs = {
    region           = var.region
    cluster_name     = var.cluster_name
    workshop_cmk_arn = component.audit.workshop_cmk_arn
    tags             = var.tags
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

  depends_on = [component.eks]

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
