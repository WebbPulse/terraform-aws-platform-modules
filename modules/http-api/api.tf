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

resource "aws_apigatewayv2_integration" "this" {
  for_each = local.resolved_integrations

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = each.value.lambda_invoke_arn
  payload_format_version = each.value.payload_format_version
  timeout_milliseconds   = each.value.timeout_milliseconds
}

resource "aws_apigatewayv2_route" "this" {
  for_each = local.resolved_open_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.value.integration].id}"
  authorization_type = each.value.authorization_type
  authorizer_id      = each.value.authorizer_id

  authorization_scopes = each.value.authorization_scopes

  lifecycle {
    precondition {
      condition     = contains(keys(var.integrations), each.value.integration)
      error_message = "Route \"${each.key}\" names integration \"${each.value.integration}\", which is not a key in var.integrations (${join(", ", keys(var.integrations))})."
    }
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = var.throttling_burst_limit
    throttling_rate_limit    = var.throttling_rate_limit
    detailed_metrics_enabled = var.detailed_metrics_enabled
  }

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

  lifecycle {
    precondition {
      condition     = length(local.unknown_route_settings) == 0
      error_message = "route_settings names routes that do not exist on this API: ${join(", ", local.unknown_route_settings)}."
    }
  }
}

resource "aws_lambda_permission" "this" {
  for_each = local.resolved_integrations

  statement_id  = each.value.statement_id
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
