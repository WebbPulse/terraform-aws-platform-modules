# Alarms for an application split into a Lambda function per domain, where the signal that matters
# is what the functions log rather than what AWS/Lambda counts.
#
# AWS/Lambda Errors counts an invocation that raised. It says nothing about a request the function
# handled without crashing and logged an error for: a failed downstream call it caught, a rejected
# payload, a retry that gave up. Those are the ones a metric filter catches, because the shared
# observability package writes them as structured JSON with a "level" field and the filter matches
# on that field.
#
# Three functions here, one filter each, and one alarm across all three. Every filter publishes to
# the same dimensionless metric, so the alarm's Sum is the total across every function and the
# alarm count stays at one however many domains the application grows.
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
# with version = "~> 1.8"; the relative path here keeps the example runnable from the repository.
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

  # One function per domain. The map key is the short domain name and becomes both the log group
  # suffix and the metric filter name, "<name>-<domain>-errors".
  domains = ["posts", "users", "auth"]
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

# The log groups are declared here rather than left to Lambda's implicit creation, so that
# retention is set and so the metric filters have something to depend on at plan time. 7 days is
# the estate standard.
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

  # JSON, not Text. A { $.level = "ERROR" } filter pattern only matches log events that parse as
  # JSON, so a function left on the Text format publishes nothing to the metric and the alarm sits
  # at OK forever. This is the single most important line in the example.
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

  # One metric filter per log group, all feeding one "<name>-application-errors" alarm. The keys
  # are what tell a responder which filter fired, so they are the domain names.
  error_log_groups = {
    for d in local.domains : d => aws_cloudwatch_log_group.domain[d].name
  }

  # Every one of these already defaults to the value shown; they are spelled out so the example
  # doubles as the list of knobs.
  error_filter_pattern           = "{ $.level = \"ERROR\" }"
  error_metric_namespace         = "WebbPulse/Application"
  error_alarm_threshold          = 0
  error_alarm_period             = 300
  error_alarm_evaluation_periods = 1

  # This application has no single "the API" function, so lambda_function_name is left unset and
  # there are no AWS/Lambda alarms by default. lambda_errors_alarm_function_name adds the errors
  # alarm back for the one function that fronts the API, without the throttles alarm.
  lambda_errors_alarm_function_name = aws_lambda_function.domain["posts"].function_name

  # One alarm across every DynamoDB table in the account, as the other example shows.
  dynamodb_aggregate_alarm = true

  # The rate limiter allows a request when it cannot reach its table, so nothing else reports the
  # limit going unenforced: the request succeeded and AWS/Lambda Errors stays at zero. This adds one
  # metric filter per log group and one "<name>-rate-limit-failed-open" alarm on the shared metric
  # they publish. The log groups are not repeated here because they default to error_log_groups.
  #
  # The default pattern { $.rate_limit_failed_open IS TRUE } matches a top level JSON field. A
  # service that instead writes the flag into its message text needs a substring pattern here, or
  # the metric stays flat at 0 and the alarm reports healthy while the limiter fails open. See the
  # module README section "The pattern has to match the shape the service actually logs".
  rate_limit_fail_open_alarm = true
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
