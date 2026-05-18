################################################################################
# EKS Module — workshop foundation
#
# Wraps terraform-aws-modules/eks/aws ~> 20.37 to provide:
#   - EKS 1.33 control plane (public + private endpoint)
#   - All 5 control-plane log types (CONTEXT decision; supports OBJ-5 forensics)
#   - Managed node group: m5.xlarge × desired=3 / min=2 / max=5 / AL2023 / on-demand
#   - EKS Access Entries (replaces aws-auth ConfigMap)
#   - 5 managed addons: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver
#   - Pod Identity Associations on vpc-cni + aws-ebs-csi-driver (RESEARCH Pattern 3)
#
# Module pinned to ~> 20.37 (matches eks-terraform-stacks reference) — v21 of
# terraform-aws-modules/eks/aws requires AWS provider 6.x, but our Stacks
# config locks AWS to ~> 5.0 (workshop CONTEXT.md decision). v20.37 supports
# the same 5 managed addons + Pod Identity Associations + Access Entries
# feature set we depend on, just under the older `cluster_*`-prefixed input
# names. v20 input shapes:
#   - `cluster_name`, `cluster_version`, `cluster_addons`
#   - `cluster_endpoint_public_access[_cidrs]`, `cluster_endpoint_private_access`
#   - `cluster_enabled_log_types`
# Output names are unchanged across v20/v21 (cluster_endpoint, etc.).
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
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = "1.34"

  # Endpoint configuration (CONTEXT decision)
  # Public + private: kubectl from attendee laptop works (public);
  # in-cluster traffic stays via private endpoint.
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"] # Workshop Studio: any IP — auth still required via Access Entries
  cluster_endpoint_private_access      = true

  # All 5 control-plane log types (CONTEXT decision; supports OBJ-5 forensics).
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Let EKS manage its own CloudWatch log group to avoid ResourceAlreadyExistsException
  # during Terraform Stacks deferred re-apply cycles.
  create_cloudwatch_log_group = false

  # K8s Secrets envelope encryption is OFF — Vault is the credential broker
  # in this architecture, K8s Secrets are largely empty (cert-manager TLS
  # material + Vault Helm internals only), and AWS already encrypts the
  # underlying etcd volume at rest. Adding a customer-managed CMK on top
  # would be defensive theater. The customer-controlled-key teaching moments
  # live in Vault auto-unseal CMK (Phase 3) + RDS storage CMK (Plan 02-04)
  # + KB / CloudWatch CMK reuse.
  #
  # Two settings together: create_kms_key = false skips CMK creation, AND
  # cluster_encryption_config = {} disables envelope encryption entirely.
  # WITHOUT the {} override the module's default
  # `{ resources = ["secrets"] }` triggers an internal for_each that
  # references provider_key_arn (a field absent from the default), causing
  # the plan to fail with two "Unsupported attribute" diagnostics.
  create_kms_key            = false
  cluster_encryption_config = {}

  # EKS Access Entries — replaces legacy aws-auth ConfigMap (CONTEXT decision).
  # Creator admin permissions ensure the HCP-deploy role is admin during apply
  # (Pitfall E3 — persists post-apply; documented in README).
  # enable_cluster_creator_admin_permissions grants the deploying IAM role
  # (which is also var.admin_principal_arn in this workshop) cluster-admin via
  # the auto-created "cluster_creator" access entry. An explicit access_entry
  # for the same principal would collide (409 ResourceInUseException).
  enable_cluster_creator_admin_permissions = true

  # Managed addons with Pod Identity Associations (RESEARCH Pattern 3).
  # before_compute=true on vpc-cni and eks-pod-identity-agent is CRITICAL —
  # nodes need CNI + Pod Identity agent before they reach Ready (Pitfall E1).
  cluster_addons = {
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
  # EDR compliance via Uptycs Helm DaemonSet (module.edr), not custom AMI.
  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m5.xlarge"]
      capacity_type  = "ON_DEMAND"
      min_size       = 3
      desired_size   = 5
      max_size       = 7
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Bump from default 30s. The cluster's primary security group (auto-created
  # by EKS at CreateCluster) needs longer than 30s to be visible to the
  # CreateNodegroup API in some regions/AZs — observed as
  # `InvalidRequestException: The security group sg-... does not exist in VPC`
  # in run sdr-rgxc91GbDFEWcBcr (2026-05-07). 60s removes the race entirely
  # at the cost of one extra minute on first apply.
  dataplane_wait_duration = "60s"

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
