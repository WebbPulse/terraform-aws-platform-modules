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
# A CloudWatch alarm may reference at most 10 metrics, so a list longer than 10 is chunked into
# groups of at most 10 and each group gets its own pair: the eleventh domain would add
# "<prefix>-lambda-errors-aggregate-2" and "<prefix>-lambda-throttles-aggregate-2". The four domains
# here are one group, which is the common case; the second module call at the bottom of this file
# shows the chunked shape without creating twelve more Lambda functions to alarm on.
#
# Summing named metrics rather than alarming on AWS/Lambda with no FunctionName dimension is the
# point: a dimensionless alarm is account wide, so it would also count the access gate's authorizer
# function and anything else running in the account.
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
# with version = "~> 2.2"; the relative path here keeps the example runnable from the repository.
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

  # One function per domain. The list order is load bearing twice over: it is the order of the
  # metric math ids inside a group, and past ten names it decides which group each function lands
  # in. Appending never re-chunks an earlier group, so grow this list at the end.
  domains = ["content", "resume", "identity", "public"]

  # Twelve names for the chunked module call below. These are not real functions: the module takes
  # names, not ARNs, so an example can show the chunking without twelve more aws_lambda_function
  # resources. A real consumer builds this list from its own for_each map, as the call above does.
  many_domains = [for i in range(1, 13) : format("%s-d%02d", local.name, i)]
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
  # rather than one per resource. The log based alarm is the one that stays a single number however
  # many functions there are, because its metric is dimensionless and carries no metric math
  # ceiling, where the AWS/Lambda alarms above chunk into a pair per ten functions.
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

# --- The same shape past the ten metric ceiling ------------------------------------------------
#
# Twelve function names is two groups, ten then two, so four alarms:
#
#   example-staging-many-lambda-errors-aggregate        m0 + ... + m9   over the first ten names
#   example-staging-many-lambda-errors-aggregate-2      m0 + m1         over the remaining two
#   example-staging-many-lambda-throttles-aggregate     the same split on Throttles
#   example-staging-many-lambda-throttles-aggregate-2
#
# The first group keeps the unsuffixed name, which is what makes upgrading from a version that
# capped the list at ten a zero-change plan for anyone at ten or fewer names. Groups past the first
# are numbered from 2.
#
# One thing to know before relying on this: lambda_aggregate_threshold applies within a group, not
# across the estate. At the default of 0 that is the same behavior as a single alarm. At a raised
# threshold it is not, and the log based alarm in error_log_groups is the shape that keeps one
# number for the whole estate.
#
# This call has its own name_prefix so its topic and alarm names do not collide with the call above.

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
