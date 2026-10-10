resource "aws_route53_record" "dkim" {
  count = local.dkim_record_count

  zone_id = local.records_zone_id
  name    = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = var.dkim_record_ttl
  records = ["${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "dmarc" {
  count = local.dmarc_count

  zone_id = local.records_zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = var.dmarc_record_ttl
  records = [var.dmarc_record]
}

data "aws_region" "current" {
  count = local.mail_from_record_count
}

resource "aws_route53_record" "mail_from_mx" {
  count = local.mail_from_record_count

  zone_id = local.records_zone_id
  name    = var.mail_from_domain
  type    = "MX"
  ttl     = var.mail_from_record_ttl
  records = ["10 feedback-smtp.${data.aws_region.current[0].region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  count = local.mail_from_record_count

  zone_id = local.records_zone_id
  name    = var.mail_from_domain
  type    = "TXT"
  ttl     = var.mail_from_record_ttl
  records = ["v=spf1 include:amazonses.com ~all"]
}
