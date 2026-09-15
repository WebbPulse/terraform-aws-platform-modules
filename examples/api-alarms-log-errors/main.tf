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
  name = "example-staging"

  domains = ["posts", "users", "auth"]
}

data "archive_file" "handler" {
  type        = "zip"
  output_path = "${path.module}/.build/handler.zip"

  source {
    filename = "index.mjs"
    content  = "export const handler = async () => ({ statusCode: 200, body: 'ok' });"
  }
}

resource "aws_iam_role" "domain" {
  name = "${local.name}-domain"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "domain_logs" {
  role       = aws_iam_role.domain.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "domain" {
  for_each = toset(local.domains)

  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = 7
}

resource "aws_lambda_function" "domain" {
  for_each = toset(local.domains)

  function_name    = "${local.name}-${each.key}"
  role             = aws_iam_role.domain.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 29

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = aws_cloudwatch_log_group.domain[each.key].name
  }

  depends_on = [aws_iam_role_policy_attachment.domain_logs]
}

module "alarms" {
  source = "../../modules/api-alarms"

  name_prefix         = local.name
  notification_emails = ["alerts@example.com"]

  error_log_groups = {
    for d in local.domains : d => aws_cloudwatch_log_group.domain[d].name
  }

  error_filter_pattern           = "{ $.level = \"ERROR\" }"
  error_metric_namespace         = "WebbPulse/Application"
  error_alarm_threshold          = 0
  error_alarm_period             = 300
  error_alarm_evaluation_periods = 1

  lambda_errors_alarm_function_name = aws_lambda_function.domain["posts"].function_name

  dynamodb_aggregate_alarm = true

  rate_limit_fail_open_alarm = true

  alarms = {
    lambda_account_errors   = false
    application_errors      = true
    rate_limit_failed_open  = true
    telemetry_export_errors = true
    dynamodb_throttles      = true
  }
}

output "alarm_topic_arn" {
  description = "Topic every alarm publishes to."
  value       = module.alarms.sns_topic_arn
}

output "error_metric_filter_names" {
  description = "The metric filter created for each domain."
  value       = module.alarms.error_metric_filter_names
}

output "error_alarm_name" {
  description = "The single alarm summing errors across every domain."
  value       = module.alarms.error_alarm_name
}

output "error_metric" {
  description = "Namespace and name of the metric the filters publish to, for a dashboard."
  value       = module.alarms.error_metric
}

output "rate_limit_fail_open_alarm_name" {
  description = "The single alarm covering the rate limiter failing open across every domain."
  value       = module.alarms.rate_limit_fail_open_alarm_name
}
