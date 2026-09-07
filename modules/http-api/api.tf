resource "aws_apigatewayv2_api" "this" {
  name                         = var.name
  protocol_type                = "HTTP"
  description                  = var.description
  disable_execute_api_endpoint = var.disable_execute_api_endpoint

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "access" {
  name              = local.access_log_group_name
  retention_in_days = var.access_log_retention_days

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_invoke_arn
  payload_format_version = var.payload_format_version
  timeout_milliseconds   = var.integration_timeout_milliseconds
}

resource "aws_apigatewayv2_route" "this" {
  for_each = toset(var.route_keys)

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = local.authorization_type
  authorizer_id      = var.authorizer_id
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

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format          = jsonencode(var.access_log_format)
  }

  tags = local.tags
}

resource "aws_lambda_permission" "api" {
  statement_id  = var.lambda_permission_statement_id
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
