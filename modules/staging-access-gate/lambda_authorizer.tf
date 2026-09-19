data "archive_file" "authorizer" {
  type        = "zip"
  output_path = "${path.module}/.build/authorizer.zip"

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
    content  = local.identity_jwt_config_json
  }
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${var.name}-access-gate-authorizer"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "authorizer" {
  name = "${var.name}-access-gate-authorizer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "authorizer" {
  name = "access-gate-authorizer"
  role = aws_iam_role.authorizer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.authorizer.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.origin_verify.arn
      },
    ]
  })
}

resource "aws_lambda_function" "authorizer" {
  function_name = "${var.name}-access-gate-authorizer"
  description   = local.identity_jwt_enabled ? "REQUEST authorizer for the ${var.name} access gate: CORS preflights, origin header, signed cookies, plus identity JWT on the route keys in identity_jwt_config.json." : "REQUEST authorizer for the ${var.name} access gate: CORS preflights, origin header, and the gate signed cookies."
  role          = aws_iam_role.authorizer.arn

  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = local.authorizer_timeout_seconds

  environment {
    variables = local.authorizer_environment
  }

  lifecycle {
    precondition {
      condition     = local.identity_jwks_fetch_timeout_ms <= (local.authorizer_timeout_seconds - 4) * 1000
      error_message = "identity_jwt.jwks_fetch_timeout_ms must stay at least 4 seconds below the authorizer function timeout, so a fetch that runs to its own deadline still leaves the invocation time to retry once and verify the signature rather than being killed mid-verification."
    }
  }

  depends_on = [aws_cloudwatch_log_group.authorizer, aws_iam_role_policy.authorizer]
}

resource "aws_apigatewayv2_authorizer" "origin_verify" {
  count = local.http_api_attached ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.http_api_id != null
      error_message = "http_api_attached is true but http_api_id is null. The authorizer has to be created on an API; pass the id, or leave http_api_attached null to derive it from the id as before."
    }
  }

  api_id                            = var.http_api_id
  name                              = "${var.name}-access-gate-origin-verify"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  identity_sources                  = []
  authorizer_result_ttl_in_seconds  = 0
}

resource "aws_lambda_permission" "authorizer" {
  count = local.http_api_attached ? 1 : 0

  statement_id  = "AllowHttpApiAuthorizerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:${data.aws_partition.current.partition}:execute-api:${local.region}:${data.aws_caller_identity.current.account_id}:${var.http_api_id}/authorizers/${aws_apigatewayv2_authorizer.origin_verify[0].id}"
}

data "aws_partition" "current" {}
