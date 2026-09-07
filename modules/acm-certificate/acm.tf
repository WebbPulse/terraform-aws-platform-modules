resource "aws_acm_certificate" "this" {
  count = local.count

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  tags = var.tags

  # A certificate in use by CloudFront or an API Gateway domain cannot be destroyed before its
  # replacement is attached, so any change that forces a new certificate creates it first.
  lifecycle {
    create_before_destroy = true
  }
}

# Written through aws.records, which the consumer points at whichever account owns the zone. Where
# the zone is in the same account as the certificate, the consumer passes its default provider for
# both.
resource "aws_route53_record" "validation" {
  provider = aws.records

  for_each = local.validation_records

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = var.validation_record_ttl
  records         = [each.value.record]
  allow_overwrite = var.allow_overwrite
}

resource "aws_acm_certificate_validation" "this" {
  count = local.count

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
