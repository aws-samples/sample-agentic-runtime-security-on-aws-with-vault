# Simple AD Module

Deploys AWS Simple AD (Small) as the LDAP identity source for IVIA OIDC Provider. Workshop test users (Oscar, Adriana) are provisioned post-deploy by `create-simple-ad-users.sh`.

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `region` | string | AWS region |
| `vpc_id` | string | VPC for Simple AD ENIs |
| `private_subnet_ids` | list(string) | Two private subnets in different AZs |
| `eks_node_security_group_id` | string | EKS node SG — allowed LDAP ingress |
| `admin_password` | string (sensitive) | Simple AD Administrator password |
| `domain_name` | string | FQDN (default: workshop.internal) |
| `short_name` | string | NetBIOS name (default: WORKSHOP) |
| `tags` | map(string) | Resource tags |

## Outputs

| Name | Description |
|------|-------------|
| `dns_ip_addresses` | LDAP host IPs for IVIA config |
| `directory_id` | Directory ID |
| `domain_name` | FQDN |
| `base_dn` | LDAP base DN (DC=workshop,DC=internal) |
| `bind_dn` | Administrator bind DN |
| `security_group_id` | Directory security group |
