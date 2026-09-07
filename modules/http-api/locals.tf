locals {
  custom_domain = var.domain_name != null
  dns_record    = local.custom_domain && var.zone_id != null

  access_log_group_name = coalesce(var.access_log_group_name, "/aws/apigateway/${var.name}")

  # An unset tags argument and an empty map plan identically on provider 5.x, but passing null
  # keeps the configuration byte-for-byte what an adopting consumer had before the move.
  tags             = length(var.tags) > 0 ? var.tags : null
  domain_name_tags = length(merge(var.tags, var.domain_name_tags)) > 0 ? merge(var.tags, var.domain_name_tags) : null

  authorization_type = var.authorizer_id == null ? "NONE" : "CUSTOM"

  api_url = local.custom_domain ? "https://${var.domain_name}" : aws_apigatewayv2_api.this.api_endpoint
}
