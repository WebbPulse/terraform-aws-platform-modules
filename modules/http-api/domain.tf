resource "aws_apigatewayv2_domain_name" "this" {
  count = local.custom_domain ? 1 : 0

  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = var.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.domain_name_tags
}

resource "aws_apigatewayv2_api_mapping" "this" {
  count = local.custom_domain ? 1 : 0

  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.this[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "alias" {
  count = local.dns_record ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.zone_id != null
      error_message = "dns_record_enabled is true but zone_id is null. The alias record has to be written into a hosted zone; pass the zone id, or leave dns_record_enabled null to derive the record from the id as before."
    }
  }

  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
