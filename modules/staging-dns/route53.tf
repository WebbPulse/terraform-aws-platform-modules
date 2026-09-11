resource "aws_route53_zone" "this" {
  count = local.zone_count

  name          = var.zone_name
  comment       = var.comment
  force_destroy = var.force_destroy
  tags          = local.zone_tags
}

resource "aws_route53_record" "delegation" {
  count    = local.delegation_count
  provider = aws.parent

  zone_id = var.parent_zone_id
  name    = var.zone_name
  type    = "NS"
  ttl     = var.delegation_ttl
  records = aws_route53_zone.this[0].name_servers
}
