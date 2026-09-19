data "archive_file" "identity_lambda" {
  count = local.identity_lambda_create ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/.build/identity-authorizer.zip"

  source {
    filename = "index.js"
    content  = file("${path.module}/lambda/authorizer/index.js")
  }

  source {
    filename = "identity.js"
    content  = file("${path.module}/../../shared/identity-authorizer/identity.js")
  }

  source {
    filename = "identity_jwt_config.json"
    content  = local.identity_lambda_config_json
  }
}

resource "aws_cloudwatch_log_group" "identity_lambda" {
  count = local.identity_lambda_create ? 1 : 0

  name              = local.identity_lambda_log_group_name
  retention_in_days = var.identity_jwt.lambda_log_retention_days

  tags = local.tags
}

resource "aws_iam_role" "identity_lambda" {
  count = local.identity_lambda_create ? 1 : 0

  name = local.identity_lambda_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "identity_lambda" {
  count = local.identity_lambda_create ? 1 : 0

  name = "identity-jwt-authorizer"
  role = aws_iam_role.identity_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.identity_lambda[0].arn}:*"
    }]
  })
}

resource "aws_lambda_function" "identity_lambda" {
  count = local.identity_lambda_create ? 1 : 0

  function_name = local.identity_lambda_name
  description   = "REQUEST authorizer for ${var.name}: verifies identity access tokens and passes configured API key bearers through."
  role          = aws_iam_role.identity_lambda[0].arn

  filename         = data.archive_file.identity_lambda[0].output_path
  source_code_hash = data.archive_file.identity_lambda[0].output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = local.identity_lambda_timeout_seconds

  environment {
    variables = local.identity_lambda_environment
  }

  lifecycle {
    precondition {
      condition     = local.identity_jwks_fetch_timeout_ms <= (local.identity_lambda_timeout_seconds - 4) * 1000
      error_message = "identity_jwt.jwks_fetch_timeout_ms must stay at least 4 seconds below the authorizer function timeout, so a fetch that runs to its own deadline still leaves the invocation time to retry once and verify the signature rather than being killed mid-verification."
    }
  }

  tags = local.tags

  depends_on = [aws_cloudwatch_log_group.identity_lambda, aws_iam_role_policy.identity_lambda]
}

resource "aws_apigatewayv2_authorizer" "identity_lambda" {
  count = local.identity_lambda_create ? 1 : 0

  api_id                            = aws_apigatewayv2_api.this.id
  name                              = local.identity_jwt_name
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.identity_lambda[0].invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  identity_sources                  = local.identity_jwt_identity_sources
  authorizer_result_ttl_in_seconds  = local.identity_lambda_result_ttl_seconds

  depends_on = [
    aws_apigatewayv2_route.this,
    aws_apigatewayv2_stage.default,
    var.identity_jwt_depends_on,
  ]

  lifecycle {
    precondition {
      condition     = length(local.identity_jwt_route_keys) > 0
      error_message = "identity_jwt is set but no route sets require_identity_jwt = true, so the authorizer would be created and attached to nothing. Mark the routes that need a token, or leave identity_jwt null."
    }
  }
}

resource "aws_lambda_permission" "identity_lambda" {
  count = local.identity_lambda_create ? 1 : 0

  statement_id  = "AllowHttpApiIdentityAuthorizerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.identity_lambda[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.identity_lambda[0].id}"
}
