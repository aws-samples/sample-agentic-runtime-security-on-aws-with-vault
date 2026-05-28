################################################################################
# VPC Module — workshop foundation
#
# Wraps terraform-aws-modules/vpc/aws ~> 5.16 to provide:
#   - 3 public + 3 private subnets across var.azs (3 AZs)
#   - Single shared NAT Gateway (cost-optimized; ephemeral workshop)
#   - S3 gateway endpoint (free)
#   - 6 interface endpoints in private subnets:
#       bedrock-runtime, bedrock-agent-runtime, logs, sts, secretsmanager, kms
#
# Subnet tags allow EKS managed node group (Plan 02-03) and the AWS Load
# Balancer Controller (Plan 02-06) to discover them.
#
# Subnets carry only ALB-controller discovery tags — no node-autoscaler
# discovery tags (managed node group only; cluster autoscaler is out of scope).
# OpenSearch Serverless stays public per CONTEXT — no AOSS interface endpoint.
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "= 5.21.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = [for k, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true # CONTEXT: cost-optimized; ephemeral workshop

  # Required for EKS
  enable_dns_hostnames = true
  enable_dns_support   = true

  # ALB controller subnet discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}

################################################################################
# VPC Endpoints — sensitive plane never touches NAT (supports OBJ-4 demo)
################################################################################

# S3 gateway endpoint (free; attached to private subnet route tables)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpce-s3" })
}

locals {
  # 6 interface endpoints required by the workshop's sensitive plane.
  # Order: Bedrock data + agent runtimes, then shared AWS auxiliary services.
  # NOTE: aoss is intentionally excluded — AOSS stays public per CONTEXT.
  interface_endpoint_services = [
    "bedrock-runtime",
    "bedrock-agent-runtime",
    "logs",
    "sts",
    "secretsmanager",
    "kms",
  ]
}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.cluster_name}-vpce-"
  vpc_id      = module.vpc.vpc_id
  description = "Allow HTTPS from VPC CIDR to interface endpoints"

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpce-sg" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpce-${each.key}" })
}
