# Alarms over a Lambda-backed HTTP API and the DynamoDB tables behind it, all reporting to one
# SNS topic with email subscribers. The function, the API and the tables belong to the consumer;
# the module owns the topic, the subscriptions and the alarms.
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
# with version = "~> 1.7", and the http-api module in front of it with version = "~> 2.0" for the
# integrations map; the relative paths here keep the example runnable from the repository.
#
# Applying this sends a confirmation email to every address in notification_emails. Until an
# address clicks the link its subscription stays pending and it receives no alarm notifications.

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

# --- The function -----------------------------------------------------------------------------

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

# --- The API ----------------------------------------------------------------------------------

module "api" {
  source = "../../modules/http-api"

  name = "${local.name}-api"

  # One backend behind the API. The key "legacy" is the module's default_integration, so this one
  # entry serves every request through the $default route.
  integrations = {
    legacy = {
      lambda_function_name = aws_lambda_function.api.function_name
      lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
    }
  }
}

# --- The tables -------------------------------------------------------------------------------

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

# --- The alarms -------------------------------------------------------------------------------

module "alarms" {
  source = "../../modules/api-alarms"

  name_prefix         = local.name
  notification_emails = ["alerts@example.com"]

  lambda_function_name = aws_lambda_function.api.function_name
  http_api_id          = module.api.api_id

  # One "<name_prefix>-dynamodb-throttles" alarm covering throttled requests across every table in
  # the account, rather than one alarm per table. It needs no table list, so dynamodb_tables stays
  # empty; the per table shape is still available by populating it instead.
  dynamodb_aggregate_alarm = true
  dynamodb_tables          = {}

  # Every threshold, period and evaluation count already defaults to the value shown here; they
  # are spelled out so the example doubles as the list of knobs.
  lambda_errors_threshold      = 0
  lambda_throttles_threshold   = 0
  api_5xx_threshold            = 0
  api_latency_statistic        = "p99"
  api_latency_threshold_ms     = 10000
  dynamodb_aggregate_threshold = 0
}

output "alarm_topic_arn" {
  description = "Topic every alarm publishes to."
  value       = module.alarms.sns_topic_arn
}

output "alarm_names" {
  description = "Every alarm the module created."
  value       = module.alarms.alarm_names
}
