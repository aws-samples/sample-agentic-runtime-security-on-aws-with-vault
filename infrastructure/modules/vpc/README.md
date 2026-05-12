# vpc

## Overview

This module wraps [`terraform-aws-modules/vpc/aws ~> 5.16`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest) to provide the workshop's single-region VPC: 3 public + 3 private subnets across 3 AZs, a single shared NAT Gateway (cost-optimized for an ephemeral workshop), an S3 gateway endpoint, and the 6 interface endpoints required for the "sensitive plane never touches NAT/internet" demonstration supporting OBJ-4. Subnet tags make it consumable by the EKS managed node group (Plan 02-03) and AWS Load Balancer Controller (Plan 02-06).

## Architecture decisions (locked)

- **Single NAT Gateway** (`single_nat_gateway = true`) — saves ~$70/mo per workshop run vs per-AZ NAT. CONTEXT cost decision; HA failover is not part of the pedagogy.
- **6 interface endpoints**: `bedrock-runtime`, `bedrock-agent-runtime`, `logs`, `sts`, `secretsmanager`, `kms`. All sit in the private subnets behind a security group that only permits 443/tcp from `var.vpc_cidr`. They demonstrate that the agent → Bedrock + Vault → KMS + audit → CloudWatch Logs paths never traverse the NAT gateway.
- **OpenSearch Serverless stays public** per CONTEXT — the `aoss` interface endpoint is intentionally NOT included.
- **S3 gateway endpoint** — free; attached to private route tables; required so KB ingestion + Bedrock model artifact pulls stay on the AWS backbone.
- **ALB controller subnet discovery** via standard tags: `kubernetes.io/role/elb=1` on public subnets, `kubernetes.io/role/internal-elb=1` on private subnets.
- **Karpenter is OUT of scope** — no `karpenter.sh/discovery` tag is applied. The cluster runs with a managed node group only (Plan 02-03).
- **Region-portable** — every region-derived string interpolates `var.region`. The module contains no string literal for the canonical region; the canonical value lives in `infrastructure/deployments.tfdeploy.hcl`.

## Inputs

| Name           | Type           | Default        | Description                                                                                                                       |
| -------------- | -------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `region`       | `string`       | _(required)_   | AWS region (canonical value flows from `deployments.tfdeploy.hcl`); used to construct interface endpoint service names.           |
| `cluster_name` | `string`       | _(required)_   | Workshop cluster name; used as VPC name prefix and for SG/endpoint `Name` tagging.                                                |
| `vpc_cidr`     | `string`       | `10.1.0.0/16`  | VPC CIDR block. Reference repo uses `10.0.0.0/16`; this workshop uses `10.1` to keep parallel deployments distinct.               |
| `azs`          | `list(string)` | _(required)_   | Exactly 3 AZs (validated). Sourced from `deployments.tfdeploy.hcl`. Subnet count is derived from this list.                       |
| `tags`         | `map(string)`  | `{}`           | Tags applied to all resources.                                                                                                    |

## Outputs

| Name                              | Description                                                                       |
| --------------------------------- | --------------------------------------------------------------------------------- |
| `vpc_id`                          | The VPC ID.                                                                       |
| `vpc_cidr`                        | The VPC's IPv4 CIDR block.                                                        |
| `private_subnet_ids`              | List of 3 private subnet IDs (one per AZ).                                        |
| `public_subnet_ids`               | List of 3 public subnet IDs (one per AZ).                                         |
| `azs`                             | List of AZs the VPC was deployed into.                                            |
| `default_security_group_id`       | The VPC's default security group ID.                                              |
| `nat_public_ips`                  | Public Elastic IP(s) of the NAT Gateway (single shared NAT; list length = 1).     |
| `vpc_endpoint_security_group_id`  | Security group ID attached to the 6 interface endpoints.                          |
| `s3_gateway_endpoint_id`          | S3 gateway endpoint ID.                                                           |
| `interface_endpoint_ids`          | Map of `service-name → endpoint-id` for the 6 sensitive-plane interface endpoints.|

## Usage

Wired from `infrastructure/main.tf`:

```hcl
module "vpc" {
  source = "./modules/vpc"

  region       = var.region
  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  azs          = var.azs
  tags         = var.tags
}
```

## Region contract

This module accepts `var.region` and MUST NOT contain a hard-coded canonical-region string literal anywhere in this directory. Single source of truth: `infrastructure/terraform.tfvars`. Plan 02-02 enforces this with a `grep` gate.

## References

- Upstream module: [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest)
- Audit-correlation context (the interface endpoints carry CloudWatch Logs egress without touching NAT): [`infrastructure/docs/audit-correlation-queries.md`](../../docs/audit-correlation-queries.md)
- Phase plan: [`02-02-PLAN.md`](../../../.planning/phases/02-foundation-infrastructure/02-02-PLAN.md)
