################################################################################
# Simple AD Module — AWS Directory Service
#
# Deploys AWS Simple AD (Small) as the LDAP identity source for IVIA OIDC
# Provider. Workshop attendees' test users (Oscar, Adriana) are provisioned
# here via create-simple-ad-users.sh after Terraform apply.
#
# Simple AD supports LDAP on port 389 only (no LDAPS). Workshop-grade —
# production would use AWS Managed Microsoft AD with LDAPS.
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_directory_service_directory" "workshop" {
  name       = var.domain_name
  short_name = var.short_name
  type       = "SimpleAD"
  size       = "Small"
  password   = var.admin_password

  vpc_settings {
    vpc_id     = var.vpc_id
    subnet_ids = slice(var.private_subnet_ids, 0, 2)
  }

  tags = merge(var.tags, {
    Name = "${var.short_name}-simple-ad"
  })
}

resource "aws_security_group_rule" "eks_to_simple_ad_ldap" {
  type                     = "ingress"
  security_group_id        = aws_directory_service_directory.workshop.security_group_id
  source_security_group_id = var.eks_node_security_group_id
  protocol                 = "tcp"
  from_port                = 389
  to_port                  = 389
  description              = "LDAP from EKS nodes to Simple AD"
}
