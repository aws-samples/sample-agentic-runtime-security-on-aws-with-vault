################################################################################
# Simple AD Module — Outputs
################################################################################

output "dns_ip_addresses" {
  description = "DNS IP addresses of the Simple AD directory controllers. Used as LDAP hosts in IVIA config.yaml."
  value       = aws_directory_service_directory.workshop.dns_ip_addresses
}

output "directory_id" {
  description = "Simple AD directory ID."
  value       = aws_directory_service_directory.workshop.id
}

output "domain_name" {
  description = "FQDN of the Simple AD directory (e.g. workshop.internal)."
  value       = aws_directory_service_directory.workshop.name
}

output "base_dn" {
  description = "LDAP base DN derived from domain name (e.g. DC=workshop,DC=internal)."
  value       = join(",", [for part in split(".", var.domain_name) : "DC=${part}"])
}

output "bind_dn" {
  description = "Administrator bind DN for LDAP operations."
  value       = "CN=Administrator,CN=Users,${join(",", [for part in split(".", var.domain_name) : "DC=${part}"])}"
}

output "security_group_id" {
  description = "Security group ID attached to the Simple AD directory."
  value       = aws_directory_service_directory.workshop.security_group_id
}
