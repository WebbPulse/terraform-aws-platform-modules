terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
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

data "archive_file" "placeholder" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_placeholder"
  output_path = "${path.module}/.terraform/lambda_placeholder.zip"
}

module "api_lambda" {
  source = "../../modules/lambda-function"

  function_name = "example-production-api"
  role_name     = "example-production-lambda-api"

  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  architectures = ["arm64"]
  memory_size   = 1024
  timeout       = 29

  code = {
    filename         = data.archive_file.placeholder.output_path
    source_code_hash = data.archive_file.placeholder.output_base64sha256
  }

  environment_variables = {
    APP_ENVIRONMENT = "production"
    LOG_LEVEL       = "INFO"
  }

  log_retention_days    = 14
  log_format            = "JSON"
  application_log_level = "INFO"
  system_log_level      = "INFO"

  enable_log_write = true
  enable_xray      = true
  app_secret_arns  = [aws_secretsmanager_secret.app.arn]

  tags = { Name = "example-production-api" }
}

resource "aws_secretsmanager_secret" "app" {
  name = "example/production/app"
}

module "api" {
  source = "../../modules/http-api"

  name = "example-production-api"

  integrations = {
    legacy = {
      lambda_function_name = module.api_lambda.function_name
      lambda_invoke_arn    = module.api_lambda.invoke_arn
    }
  }
}
