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
