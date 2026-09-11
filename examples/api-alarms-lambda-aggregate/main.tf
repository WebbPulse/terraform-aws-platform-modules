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

  domains = ["content", "resume", "identity", "public"]

  many_domains = [for i in range(1, 13) : format("%s-d%02d", local.name, i)]
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

  lambda_function_names  = [for d in local.domains : aws_lambda_function.domain[d].function_name]
  lambda_aggregate_alarm = true

  lambda_aggregate_threshold          = 0
  lambda_aggregate_period             = 300
  lambda_aggregate_evaluation_periods = 1

  error_log_groups = {
    for d in local.domains : d => aws_cloudwatch_log_group.domain[d].name
  }
  dynamodb_aggregate_alarm = true
}

output "alarm_topic_arn" {
  description = "Topic every alarm publishes to."
  value       = module.alarms.sns_topic_arn
}

output "lambda_aggregate_alarm_names" {
  description = "The two alarms covering AWS/Lambda across every domain, errors first."
  value       = module.alarms.lambda_aggregate_alarm_names
}

output "alarm_names" {
  description = "Every alarm the module created. Two for Lambda at this domain count."
  value       = module.alarms.alarm_names
}

module "alarms_chunked" {
  source = "../../modules/api-alarms"

  name_prefix         = "${local.name}-many"
  notification_emails = ["alerts@example.com"]

  lambda_function_names  = local.many_domains
  lambda_aggregate_alarm = true
}

output "chunked_errors_alarm_names" {
  description = "One aggregate errors alarm per group of ten function names, in chunk order."
  value       = module.alarms_chunked.lambda_aggregate_errors_alarm_names
}

output "chunked_throttles_alarm_names" {
  description = "One aggregate throttles alarm per group of ten function names, in chunk order."
  value       = module.alarms_chunked.lambda_aggregate_throttles_alarm_names
}

output "chunked_function_name_groups" {
  description = "Which function names the module put in which group, in the same order as the alarm outputs. A runbook uses this to say which alarm covers which function."
  value       = module.alarms_chunked.lambda_aggregate_function_name_chunks
}
