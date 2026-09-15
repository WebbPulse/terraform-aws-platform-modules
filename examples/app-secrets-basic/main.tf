module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 2.22"

  name_prefix = "example-production"

  secrets = {
    "secret-key" = {
      description = "JWT signing key for the API"
      value       = var.secret_key
      version     = 1
    }

    "app" = {
      description = "JSON map of runtime secrets read by the Lambda API at cold start"
      version     = 1
      json = {
        SECRET_KEY = var.secret_key
        SENTRY_DSN = var.sentry_dsn
      }
    }
  }

  policy_secret_keys = ["app"]
}

variable "secret_key" {
  description = "JWT signing key for the API"
  type        = string
  sensitive   = true
}

variable "sentry_dsn" {
  description = "Sentry DSN for backend error reporting. Empty disables Sentry."
  type        = string
  sensitive   = true
  default     = ""
}

resource "aws_iam_role" "api" {
  name = "example-production-api"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "api_secrets" {
  name   = "app-secrets"
  role   = aws_iam_role.api.id
  policy = module.app_secrets.read_policy_json
}

resource "aws_lambda_function" "api" {
  function_name = "example-production-api"
  role          = aws_iam_role.api.arn
  handler       = "app.handler"
  runtime       = "python3.13"
  filename      = "placeholder.zip"

  environment {
    variables = {
      APP_SECRETS_ARN = module.app_secrets.arns["app"]
    }
  }
}
