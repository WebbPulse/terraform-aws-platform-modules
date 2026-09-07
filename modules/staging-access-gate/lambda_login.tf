data "archive_file" "login" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/login"
  output_path = "${path.module}/.build/login.zip"
}

resource "aws_cloudwatch_log_group" "login" {
  name              = "/aws/lambda/${var.name}-access-gate-login"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "login" {
  name = "${var.name}-access-gate-login"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "login" {
  name = "access-gate-login"
  role = aws_iam_role.login.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.login.arn}:*"
      },
      {
        Effect = "Allow"
        Action = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.signing_key.arn,
          aws_ssm_parameter.client_secret.arn,
        ]
      },
    ]
  })
}

resource "aws_lambda_function" "login" {
  function_name = "${var.name}-access-gate-login"
  description   = "Cognito code exchange and CloudFront signed cookie issuer for the ${var.name} access gate."
  role          = aws_iam_role.login.arn

  filename         = data.archive_file.login.output_path
  source_code_hash = data.archive_file.login.output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      COGNITO_DOMAIN      = local.hosted_ui_domain
      COGNITO_ISSUER      = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
      CLIENT_ID           = aws_cognito_user_pool_client.login.id
      CLIENT_SECRET_PARAM = aws_ssm_parameter.client_secret.name
      SIGNING_KEY_PARAM   = aws_ssm_parameter.signing_key.name
      KEY_PAIR_ID         = aws_cloudfront_public_key.signing.id
      COOKIE_DOMAIN       = var.cookie_domain
      SITE_HOST           = var.site_host
      ALLOWED_HOSTS       = join(",", local.all_hosts)
      ALLOWED_EMAILS      = join(",", [for e in var.allowed_emails : lower(e)])
      AUTH_PREFIX         = var.auth_path_prefix
      SESSION_SECONDS     = tostring(var.session_hours * 3600)
      NODE_OPTIONS        = "--enable-source-maps"
    }
  }

  depends_on = [aws_cloudwatch_log_group.login, aws_iam_role_policy.login]
}

resource "aws_lambda_function_url" "login" {
  function_name      = aws_lambda_function.login.function_name
  authorization_type = "AWS_IAM"
  invoke_mode        = "BUFFERED"
}

resource "aws_lambda_permission" "login_url" {
  statement_id           = "AllowCloudFrontInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.login.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = coalesce(var.cloudfront_distribution_arn, "arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*")
  function_url_auth_type = "AWS_IAM"
}
