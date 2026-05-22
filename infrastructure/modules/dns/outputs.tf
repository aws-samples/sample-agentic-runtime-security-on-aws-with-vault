output "zone_id" {
  description = "Route53 hosted zone ID for the delegated subdomain."
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "The 4 Route53 name servers. Add these as an NS record set for the subdomain at the parent domain's DNS host to complete delegation."
  value       = aws_route53_zone.this.name_servers
}

output "certificate_arn" {
  description = "Validated wildcard ACM certificate ARN. Referenced by the ALB ingress certificate-arn annotation; gated on validation completion."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "domain_name" {
  description = "The delegated subdomain (zone apex)."
  value       = var.domain_name
}
