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

  tags = { Name = "example-production-api" }
}

data "aws_iam_policy_document" "runtime" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${module.api_lambda.log_group_arn}:*"]
  }

  statement {
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "runtime"
  role   = module.api_lambda.role_id
  policy = data.aws_iam_policy_document.runtime.json
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
