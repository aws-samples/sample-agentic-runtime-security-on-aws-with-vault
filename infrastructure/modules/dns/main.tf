#-------------------------------------------------------------------------------
# Workshop DNS + TLS — AWS-native (ACM public cert + Route53), NOT Vault PKI.
#
# Browser-facing HTTPS for the workshop must present a publicly-valid cert
# (Amazon Trust Services root, trusted by all browsers — zero attendee setup).
# Vault PKI is a private CA and was explicitly rejected for this use case.
#
# This module owns a Route53 public hosted zone for a delegated subdomain plus
# a wildcard ACM cert. The parent domain (devopsoscar.dev, on Google Cloud DNS)
# delegates the subdomain by adding an NS record set pointing at this zone's
# name_servers (a one-time manual step at the registrar). Once delegation is
# live, the DNS-validation records below resolve and ACM issues the cert.
#
# The ACM cert is created in the default provider region (var.region = us-west-2)
# because an ALB HTTPS listener can only reference an ACM cert co-located in the
# ALB's own region.
#-------------------------------------------------------------------------------

resource "aws_route53_zone" "this" {
  name = var.domain_name
  tags = var.tags
}

# Wildcard cert covers every workshop host under the subdomain (bank.*, login.*,
# and anything added later) with a single validation. No apex SAN: nothing is
# served at demos.devopsoscar.dev itself, and adding it would emit a second
# validation option sharing the wildcard's record name (a duplicate write).
resource "aws_acm_certificate" "this" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# One validation record per distinct (name,type) ACM asks for. Wildcard + apex
# collapse to the same validation record, so dedupe by record name.
resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until ACM observes the validation record and issues the cert. Consumers
# read certificate_arn from THIS resource (not the certificate directly) so ALB
# listeners never reference an un-issued cert.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
