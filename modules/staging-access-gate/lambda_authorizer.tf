# The authorizer package is assembled file by file rather than zipped from the source directory,
# because one of its files does not exist on disk: identity_jwt_config.json is rendered from the
# module's inputs at plan time and written straight into the archive.
#
# WHY THAT FILE EXISTS. The route keys that require an identity token used to travel to the function
# in IDENTITY_JWT_ROUTE_KEYS, and the CloudFront signing public key in SIGNING_PUBLIC_KEY_PEM. A
# Lambda's whole environment is capped at 4096 bytes across every variable, and the API measures it
# only at UpdateFunctionConfiguration: Terraform's plan is green and the apply fails with
# "environment variables exceeded the 4KB limit". CarModPicker staging hit it at 95 route keys,
# where the list alone serialised to 3600 bytes against 869 bytes of everything else. The list
# cannot be trimmed (a key missing from it is a route nobody enforces) and it cannot be prefix
# matched (the anonymous guard routes exist precisely because prefix matching is unsafe), so the two
# large values move out of the environment and into the deployment package, which has no such cap.
#
# source_content_filename entries participate in the archive's output_base64sha256 exactly as real
# files do, so a route key added to the list changes source_code_hash and Terraform redeploys the
# code. That is the whole reason this is rendered into the zip rather than uploaded beside it.
data "archive_file" "authorizer" {
  type        = "zip"
  output_path = "${path.module}/.build/authorizer.zip"

  source {
    filename = "index.js"
    content  = file("${path.module}/lambda/authorizer/index.js")
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
  timeout          = 5

  environment {
    # Small, bounded values only. Everything whose size grows with the consumer's configuration (the
    # route key list, the signing public key PEM) lives in identity_jwt_config.json inside the
    # package instead; see the archive above for why. Keeping this map bounded is what stops the
    # 4096 byte whole-environment cap from being reachable at all, and local.authorizer_environment
    # is asserted against that cap by the module's test suite.
    variables = local.authorizer_environment
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
