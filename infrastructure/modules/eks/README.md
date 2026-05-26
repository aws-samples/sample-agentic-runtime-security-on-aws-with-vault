# eks

Phase 2 root module call that builds the EKS 1.34 control plane, a managed
node group, EKS Access Entries, and 5 managed addons (with Pod Identity for
the two addons that need IAM). This is the source of truth for **INFR-02**
(Kubernetes 1.34 cluster + managed node group + control-plane logs + Access
Entries) and **INFR-05** (workshop-attendee `kubectl` one-liner).

## Overview

Wraps **`terraform-aws-modules/eks/aws ~> 20.37`** plus
**`terraform-aws-modules/eks-pod-identity/aws ~> 1.12`** (twice — once each for
the vpc-cni and aws-ebs-csi-driver Pod Identity targets). The cluster sits in
the private subnets created by the `vpc` module (Plan 02-02), and its
endpoint is reachable both privately (in-cluster) and publicly (attendee
laptop kubectl). The 5 control-plane log streams flow into EKS-managed
CloudWatch log groups; the workshop CMK from the `audit` module is
intentionally **not** wired here (see Decisions).

The cluster is the K8s substrate for everything in Phase 3+: Vault Raft (3
pods, one per AZ), IBM Verify Identity Access, the three UC agent pods, the
ALB controller, cert-manager, and external-dns.

## Decisions (locked from CONTEXT)

| Decision                                         | Value                                                                                          |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Kubernetes version                               | **1.34** (latest GA at workshop time)                                                          |
| Node management                                  | Managed node group only — **Karpenter is OUT of scope**                                        |
| Node group sizing                                | m5.xlarge × **desired=3 / min=2 / max=5**, AL2023, on-demand                                   |
| Control-plane log types                          | All 5: `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`                       |
| API endpoint access                              | Public + private (Workshop Studio: public CIDR `0.0.0.0/0`)                                    |
| Authentication mode                              | **EKS Access Entries** (replaces legacy `aws-auth` ConfigMap)                                  |
| K8s Secrets envelope encryption                  | AWS-managed key `aws/eks` — **NOT** customer-managed CMK (Vault is the credential broker)      |
| Pod IAM strategy                                 | **EKS Pod Identity** (NOT IRSA) — managed addons that need IAM use `pod_identity_association`  |
| GitOps controller                                | None — **ArgoCD is OUT of scope**                                                              |

The K8s Secrets decision is worth re-stating: in this architecture Vault is
the central credential broker, AWS Secrets Manager holds bootstrap-only
secrets, and K8s Secrets are largely empty (cert-manager TLS material + Vault
Helm internals only). A customer-managed CMK on K8s Secrets here would be
defensive theater — the customer-controlled-key teaching moment lives
instead in load-bearing places: Vault auto-unseal CMK (Phase 3), RDS storage
CMK (Plan 02-04), and OpenSearch / CloudWatch CMK reuse (Plan 02-05).

## Inputs

| Name                  | Type           | Description                                                                                                |
| --------------------- | -------------- | ---------------------------------------------------------------------------------------------------------- |
| `region`              | `string`       | AWS region (canonical region from `terraform.tfvars`; used to format `kubectl_config_command`)             |
| `cluster_name`        | `string`       | Name of the EKS cluster                                                                                    |
| `vpc_id`              | `string`       | VPC ID — passed from `module.vpc.vpc_id`                                                                   |
| `private_subnet_ids`  | `list(string)` | Private subnet IDs for the control plane and managed node group — `module.vpc.private_subnet_ids`          |
| `admin_principal_arn` | `string`       | ARN of the IAM principal granted `AmazonEKSClusterAdminPolicy` via Access Entries                          |
| `tags`                | `map(string)`  | Tags applied to all EKS resources                                                                          |

## Outputs

| Name                                 | Description                                                                                                              |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `cluster_name`                       | EKS cluster name                                                                                                         |
| `cluster_endpoint`                   | EKS API server endpoint                                                                                                  |
| `cluster_oidc_issuer`                | OIDC issuer URL (kept for backwards compat — Pod Identity is preferred over IRSA in this workshop)                       |
| `cluster_security_group_id`          | Control plane security group ID                                                                                          |
| `cluster_certificate_authority_data` | Base64-encoded CA bundle (consumed by `kubernetes`/`helm` provider configs in `providers.tf`)                            |
| `node_security_group_id`             | Managed node group security group ID                                                                                     |
| `cluster_token`                      | Short-lived auth token from `data.aws_eks_cluster_auth` (consumed by `kubernetes`/`helm` providers in root module)       |
| `kubectl_config_command`             | The one-liner attendees run to populate `~/.kube/config` (**INFR-05**)                                                   |

## Root module wiring

`infrastructure/main.tf` declares the EKS module as a Wave 1 dependency on `vpc` + `audit`:

```hcl
module "eks" {
  source = "./modules/eks"

  depends_on = [module.vpc, module.audit]

  region              = var.region
  cluster_name        = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  admin_principal_arn = var.admin_principal_arn
  tags                = var.tags
}
```

The `cluster_endpoint` + `cluster_certificate_authority_data` + `cluster_token`
outputs flow into the `kubernetes` and `helm` provider configurations in
`providers.tf`, which the `addons` module (and Phase 3's Vault / IVIA modules) consume.

## kubectl one-liner (INFR-05)

The `kubectl_config_command` output produces the workshop one-liner:

```bash
# Once the workspace apply finishes, attendees run:
aws eks update-kubeconfig --region <region> --name <cluster_name> --alias workshop
kubectl get nodes
```

The output value is shaped as:

```
aws eks update-kubeconfig --region <region> --name <cluster_name> --alias workshop
```

`<region>` and `<cluster_name>` interpolate from `var.region` and
`module.eks.cluster_name` — there is no hard-coded region literal anywhere in
this module (canonical-region contract per ROADMAP success criterion #3 — the
only place a region string lives is `terraform.tfvars`).

## Pitfalls addressed

This module is structured to neutralize three EKS-specific pitfalls catalogued
in `02-RESEARCH.md`:

- **E1 — `before_compute` on vpc-cni and pod-identity-agent.** Both addons
  need to be installed *before* nodes attempt to bootstrap; otherwise nodes
  never reach `Ready` because they cannot pull pod-network IPs (vpc-cni) or
  retrieve their Pod Identity tokens (pod-identity-agent). `main.tf` sets
  `before_compute = true` on both.
- **E2 — Public-CIDR-allowlisted endpoint without admin Access Entry creates a
  locked-out cluster.** `access_entries.workshop_admin` grants the
  `var.admin_principal_arn` `AmazonEKSClusterAdminPolicy` so the endpoint is
  reachable from any Workshop Studio attendee IP without leaving the cluster
  unreachable.
- **E3 — Cluster creator admin permissions persist post-apply.**
  `enable_cluster_creator_admin_permissions = true` is needed during the
  initial apply (otherwise the apply principal cannot bootstrap the cluster),
  but it persists in cluster state after teardown. Workshop accounts are
  ephemeral so this is acceptable; a long-lived environment would scrub the
  creator admin entry post-apply.

## References

- [`terraform-aws-modules/eks/aws` — module docs](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)
- [`terraform-aws-modules/eks-pod-identity/aws` — module docs](https://registry.terraform.io/modules/terraform-aws-modules/eks-pod-identity/aws/latest)
- [Amazon EKS Pod Identity user guide](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [Amazon EKS Access Entries user guide](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)
