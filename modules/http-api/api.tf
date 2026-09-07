resource "aws_apigatewayv2_api" "this" {
  name                         = var.name
  protocol_type                = "HTTP"
  description                  = var.description
  disable_execute_api_endpoint = var.disable_execute_api_endpoint

  dynamic "cors_configuration" {
    for_each = var.cors_configuration == null ? [] : [var.cors_configuration]

    content {
      allow_credentials = cors_configuration.value.allow_credentials
      allow_headers     = cors_configuration.value.allow_headers
      allow_methods     = cors_configuration.value.allow_methods
      allow_origins     = cors_configuration.value.allow_origins
      expose_headers    = cors_configuration.value.expose_headers
      max_age           = cors_configuration.value.max_age
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "access" {
  name              = local.access_log_group_name
  retention_in_days = var.access_log_retention_days

  tags = local.tags
}

# One AWS_PROXY integration per backend. The for_each key is the integrations key, so adding a
# prefix's function is a pure add and removing one touches nothing else.
resource "aws_apigatewayv2_integration" "this" {
  for_each = local.resolved_integrations

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = each.value.lambda_invoke_arn
  payload_format_version = each.value.payload_format_version
  timeout_milliseconds   = each.value.timeout_milliseconds
}

# One route per entry in local.all_routes, which is var.routes plus the synthesised $default. Every
# route goes through local.resolved_routes, so authorization is never left off by accident.
resource "aws_apigatewayv2_route" "this" {
  for_each = local.resolved_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.value.integration].id}"
  authorization_type = each.value.authorization_type
  authorizer_id      = each.value.authorizer_id

  authorization_scopes = each.value.authorization_scopes
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Layer 1 of the estate's rate limiting: the whole API, every route that has no override.
  default_route_settings {
    throttling_burst_limit   = var.throttling_burst_limit
    throttling_rate_limit    = var.throttling_rate_limit
    detailed_metrics_enabled = var.detailed_metrics_enabled
  }

  # Per-route overrides for the paths that need a different limit from the rest of the API.
  dynamic "route_settings" {
    for_each = var.route_settings

    content {
      route_key                = route_settings.key
      throttling_burst_limit   = route_settings.value.throttling_burst_limit
      throttling_rate_limit    = route_settings.value.throttling_rate_limit
      detailed_metrics_enabled = route_settings.value.detailed_metrics_enabled
    }
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format          = jsonencode(var.access_log_format)
  }

  tags = local.tags

  # A route_settings block for a route that does not exist is accepted by the API and then applies
  # to nothing, so the module refuses to create the stage rather than silently drop a limit.
  lifecycle {
    precondition {
      condition     = length(local.unknown_route_settings) == 0
      error_message = "route_settings names routes that do not exist on this API: ${join(", ", local.unknown_route_settings)}."
    }
  }
}

# One resource-based invoke permission per backend, scoped to this API. The source_arn covers every
# stage and route on the API, so a function keeps working when a prefix's route key changes.
resource "aws_lambda_permission" "this" {
  for_each = local.resolved_integrations

  statement_id  = each.value.statement_id
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
