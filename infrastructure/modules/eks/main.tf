################################################################################
# EKS Module — workshop foundation
#
# Wraps terraform-aws-modules/eks/aws ~> 21.0 to provide:
#   - EKS 1.33 control plane (public + private endpoint)
#   - All 5 control-plane log types (CONTEXT decision; supports OBJ-5 forensics)
#   - Managed node group: m5.xlarge × desired=3 / min=2 / max=5 / AL2023 / on-demand
#   - EKS Access Entries (replaces aws-auth ConfigMap)
#   - 5 managed addons: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver
#   - Pod Identity Associations on vpc-cni + aws-ebs-csi-driver (RESEARCH Pattern 3)
#
# IMPORTANT — terraform-aws-modules/eks/aws v21 input naming:
# v21 dropped the `cluster_` prefix on many inputs (`cluster_name` → `name`,
# `cluster_version` → `kubernetes_version`, `cluster_addons` → `addons`,
# `cluster_endpoint_*` → `endpoint_*`, `cluster_enabled_log_types` →
# `enabled_log_types`). Output names still carry the `cluster_` prefix
# (e.g. `cluster_endpoint`, `cluster_certificate_authority_data`).
#
# Karpenter and ArgoCD are deliberately OUT of scope for this workshop —
# managed node group only; Helm-direct or Stacks for app deployments.
# Do NOT add karpenter.sh/discovery tags, Karpenter NodePool/EC2NodeClass
# resources, or ArgoCD helm_release blocks here.
#
# K8s Secrets envelope encryption uses the AWS-managed key (aws/eks). Vault is
# the credential broker in this architecture; K8s Secrets are largely empty
# (cert-manager TLS material + Vault Helm internals only). Customer-managed
# CMK here would be defensive theater — see CONTEXT decision log. The
# customer-controlled-key teaching moment lives in Vault auto-unseal CMK
# (Phase 3) + RDS storage CMK (Plan 02-04) + KB / CloudWatch CMK reuse.
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = "1.33"

  # Endpoint configuration (CONTEXT decision)
  # Public + private: kubectl from attendee laptop works (public);
  # in-cluster traffic stays via private endpoint.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = ["0.0.0.0/0"] # Workshop Studio: any IP — auth still required via Access Entries
  endpoint_private_access      = true

  # All 5 control-plane log types (CONTEXT decision; supports OBJ-5 forensics).
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Let EKS manage its own CloudWatch log group to avoid ResourceAlreadyExistsException
  # during Terraform Stacks deferred re-apply cycles.
  create_cloudwatch_log_group = false

  # K8s Secrets envelope encryption deliberately uses the AWS-managed key.
  # Do NOT add an encryption_config block referencing a customer-managed CMK
  # here — Vault is the credential broker; K8s Secrets are largely empty.
  # Module v21 default: create_kms_key=false will skip CMK creation (paired
  # with no encryption_config below).
  create_kms_key = false

  # EKS Access Entries — replaces legacy aws-auth ConfigMap (CONTEXT decision).
  # Creator admin permissions ensure the HCP-deploy role is admin during apply
  # (Pitfall E3 — persists post-apply; documented in README).
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    workshop_admin = {
      principal_arn = var.admin_principal_arn
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  # Managed addons with Pod Identity Associations (RESEARCH Pattern 3).
  # before_compute=true on vpc-cni and eks-pod-identity-agent is CRITICAL —
  # nodes need CNI + Pod Identity agent before they reach Ready (Pitfall E1).
  addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
      pod_identity_association = [{
        role_arn        = module.vpc_cni_pod_identity.iam_role_arn
        service_account = "aws-node"
      }]
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # Managed node group (CONTEXT-locked sizing).
  # 3 m5.xlarge gives comfortable headroom for Vault Raft + IVIA + 3 agents +
  # ALB controller + CoreDNS. AL2023 + on-demand for predictable workshop demos.
  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m5.xlarge"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      desired_size   = 3
      max_size       = 5
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  tags = var.tags
}

################################################################################
# Cluster Authentication Token
# Required for kubernetes/helm providers in Terraform Stacks (remote execution).
# Wired into provider "kubernetes" / provider "helm" blocks via the
# component.eks.cluster_token output.
################################################################################

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}
