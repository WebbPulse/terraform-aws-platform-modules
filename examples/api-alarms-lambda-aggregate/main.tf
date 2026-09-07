# Alarms for an application split into a Lambda function per domain, where the AWS/Lambda signal
# is wanted as one number for the estate rather than as a pair of alarms per function.
#
# lambda_function_name is the one function form: it creates "<prefix>-lambda-errors" and
# "<prefix>-lambda-throttles" on a single FunctionName dimension. Four functions on that input
# would mean four module calls, eight alarms, eight billable alarm metrics and eight names to
# subscribe and document, and every new domain would add two more.
#
# lambda_function_names plus lambda_aggregate_alarm is the many function form: two alarms for the
# whole estate, "<prefix>-lambda-errors-aggregate" and "<prefix>-lambda-throttles-aggregate", each
# a metric math SUM over one metric per listed function. Adding a fifth domain changes the
# expression on the existing alarms rather than creating another pair.
#
# Summing named metrics rather than alarming on AWS/Lambda with no FunctionName dimension is the
# point: a dimensionless alarm is account wide, so it would also count the access gate's authorizer
# function and anything else running in the account.
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
# with version = "~> 2.1"; the relative path here keeps the example runnable from the repository.
#
# The HTTP API in front of these functions is left out: http_api_id is unrelated to the Lambda
# shape and examples/api-alarms-basic already shows it.
#
# Applying this sends a confirmation email to every address in notification_emails.

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

  # One function per domain. The list order is the order of the metric math ids in the aggregate
  # alarms, so keeping it stable keeps the alarm definition stable.
  domains = ["content", "resume", "identity", "public"]
}

# --- The per domain functions -----------------------------------------------------------------

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

# --- The alarms -------------------------------------------------------------------------------

module "alarms" {
  source = "../../modules/api-alarms"

  name_prefix         = local.name
  notification_emails = ["alerts@example.com"]

  # The many function form. lambda_function_name stays unset: exactly one of the two forms may be
  # set, and the module rejects a plan that sets both.
  lambda_function_names  = [for d in local.domains : aws_lambda_function.domain[d].function_name]
  lambda_aggregate_alarm = true

  # Every one of these already defaults to the value shown; they are spelled out so the example
  # doubles as the list of knobs. One threshold covers both aggregate alarms.
  lambda_aggregate_threshold          = 0
  lambda_aggregate_period             = 300
  lambda_aggregate_evaluation_periods = 1

  # The other two aggregate shapes in the module, for the same reason: one alarm for the estate
  # rather than one per resource. The log based alarm is the one that keeps working past 10
  # functions, because its metric is dimensionless and carries no metric math ceiling.
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
  description = "Every alarm the module created. Two for Lambda however many domains there are."
  value       = module.alarms.alarm_names
}
