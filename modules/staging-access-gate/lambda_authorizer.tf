data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/authorizer"
  output_path = "${path.module}/.build/authorizer.zip"
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
  description   = local.identity_jwt_enabled ? "REQUEST authorizer for the ${var.name} access gate: CORS preflights, origin header, signed cookies, plus identity JWT on IDENTITY_JWT_ROUTE_KEYS routes." : "REQUEST authorizer for the ${var.name} access gate: CORS preflights, origin header, and the gate signed cookies."
  role          = aws_iam_role.authorizer.arn

  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 5

  environment {
    # The identity block is merged rather than set to empty strings, so a gate with no token
    # enforcement has exactly the environment it had before that feature existed and shows no diff.
    variables = merge({
      HEADER_NAME         = lower(var.origin_verify_header_name)
      ORIGIN_VERIFY_PARAM = aws_ssm_parameter.origin_verify.name
      COOKIE_DOMAIN       = var.cookie_domain
      KEY_PAIR_ID         = aws_cloudfront_public_key.signing.id

      # The public half of the signing key pair. Not a secret: CloudFront publishes it, and it only
      # verifies signatures, so an environment variable is the right place for it.
      SIGNING_PUBLIC_KEY_PEM = tls_private_key.signing.public_key_pem
      },
      local.identity_jwt_environment,
    )
  }

  depends_on = [aws_cloudwatch_log_group.authorizer, aws_iam_role_policy.authorizer]
}

resource "aws_apigatewayv2_authorizer" "origin_verify" {
  count = var.http_api_id == null ? 0 : 1

  api_id                            = var.http_api_id
  name                              = "${var.name}-access-gate-origin-verify"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  # No identity sources: the authorizer has two accepted credentials (the origin verification
  # header and the gate's signed cookies), and API Gateway requires every listed identity source to
  # be present or it answers 401 without invoking the function. Identity sources are optional, and
  # dropping them means the answer cannot be cached ("To enable caching, your authorizer must have
  # at least one identity source"), so the TTL is 0 and the function runs on every request. It is a
  # 128 MB Node function whose only remote call is an SSM read cached per execution environment.
  identity_sources                 = []
  authorizer_result_ttl_in_seconds = 0
}

resource "aws_lambda_permission" "authorizer" {
  count = var.http_api_id == null ? 0 : 1

  statement_id  = "AllowHttpApiAuthorizerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:${data.aws_partition.current.partition}:execute-api:${local.region}:${data.aws_caller_identity.current.account_id}:${var.http_api_id}/authorizers/${aws_apigatewayv2_authorizer.origin_verify[0].id}"
}

data "aws_partition" "current" {}
