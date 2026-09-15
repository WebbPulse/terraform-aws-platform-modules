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

locals {
  name = "example-production"

  table_keys = ["users", "posts"]
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

resource "aws_iam_role_policy_attachment" "api_logs" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "api" {
  function_name    = "${local.name}-api"
  role             = aws_iam_role.api.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 29
}

module "api" {
  source = "../../modules/http-api"

  name = "${local.name}-api"

  integrations = {
    legacy = {
      lambda_function_name = aws_lambda_function.api.function_name
      lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
    }
  }
}

resource "aws_dynamodb_table" "tables" {
  for_each = toset(local.table_keys)

  name         = "${local.name}-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

module "alarms" {
  source = "../../modules/api-alarms"

  name_prefix         = local.name
  notification_emails = ["alerts@example.com"]

  http_api_id = module.api.api_id

  dynamodb_aggregate_alarm = true
  dynamodb_tables          = {}

  alarms = {
    api_integration_latency = true
    dynamodb_throttles      = true
  }

  lambda_account_errors_threshold    = 0
  lambda_account_throttles_threshold = 0
  api_5xx_threshold                  = 0
  api_latency_statistic              = "p99"
  api_latency_threshold_ms           = 10000
  dynamodb_aggregate_threshold       = 0
}

output "alarm_topic_arn" {
  description = "Topic every alarm publishes to."
  value       = module.alarms.sns_topic_arn
}

output "alarm_names" {
  description = "Every alarm the module created."
  value       = module.alarms.alarm_names
}
