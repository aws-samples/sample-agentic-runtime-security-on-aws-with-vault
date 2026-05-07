################################################################################
# VPC Module Outputs
################################################################################

output "vpc_id" {
  description = "The ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "The IPv4 CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "List of IDs of private subnets (3 AZs)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "List of IDs of public subnets (3 AZs)."
  value       = module.vpc.public_subnets
}

output "azs" {
  description = "List of availability zones the VPC was deployed into (echoed from var.azs)."
  value       = module.vpc.azs
}

output "default_security_group_id" {
  description = "The ID of the VPC's default security group."
  value       = module.vpc.default_security_group_id
}

output "nat_public_ips" {
  description = "Public Elastic IP(s) attached to the NAT Gateway (single shared NAT — list length = 1)."
  value       = module.vpc.nat_public_ips
}

output "vpc_endpoint_security_group_id" {
  description = "ID of the security group attached to the 6 interface endpoints."
  value       = aws_security_group.vpc_endpoints.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_ids" {
  description = "Map of service name → interface endpoint ID for the 6 sensitive-plane endpoints."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}
