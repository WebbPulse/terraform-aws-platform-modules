# Alias records in the consumer's own account. Records that belong in a zone another account owns
# stay with the consumer, because a module has exactly one aws provider and it is the one that
# owns the bucket and the distribution.

resource "aws_route53_record" "alias_a" {
  for_each = local.dns_records_a

  zone_id = var.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alias_aaaa" {
  for_each = local.dns_records_aaaa

  zone_id = var.zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
