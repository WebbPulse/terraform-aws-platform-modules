terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

locals {
  name     = "example-production"
  api_host = "api.example.com"
}

data "archive_file" "handler" {
  type        = "zip"
  output_path = "${path.module}/.build/handler.zip"

  source {
    filename = "index.mjs"
    content  = "export const handler = async () => ({ statusCode: 200, body: 'ok' });"
  }
}

resource "aws_iam_role" "api" {
  name = "${local.name}-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_lambda_function" "api" {
  function_name    = "${local.name}-api"
  role             = aws_iam_role.api.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
}

module "api" {
  source = "../../modules/http-api"

  name        = "${local.name}-api"
  description = "Production API admitting identity tokens and agent API keys"

  integrations = {
    api = {
      lambda_function_name = aws_lambda_function.api.function_name
      lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
    }
  }

  default_integration = "api"

  routes = {
    "GET /api/auth/me" = {
      integration          = "api"
      require_identity_jwt = true
    }

    "ANY /api/projects" = {
      integration          = "api"
      require_identity_jwt = true
    }

    "ANY /api/projects/{proxy+}" = {
      integration          = "api"
      require_identity_jwt = true
    }
  }

  identity_jwt = {
    issuer   = "https://${local.api_host}/api/auth"
    audience = "${local.name}-api"

    mode             = "lambda"
    api_key_prefixes = ["wpk_"]
  }
}

output "identity_jwt_mode" {
  description = "Which authorizer is enforcing the marked routes."
  value       = module.api.identity_jwt_mode
}

output "identity_authorizer_log_group_name" {
  description = "Where an unexplained 401 on a marked route is explained."
  value       = module.api.identity_authorizer_log_group_name
}

output "identity_api_key_prefixes" {
  description = "Bearer prefixes reaching the backend without claims."
  value       = module.api.identity_api_key_prefixes
}
