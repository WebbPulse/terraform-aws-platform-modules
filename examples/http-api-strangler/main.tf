# The strangler shape: one monolith Lambda still answering everything, with two prefixes already
# carved off onto their own per-domain functions.
#
# The monolith is the "legacy" integration and default_integration points at it, so $default keeps
# catching every path nobody has claimed yet. Each prefix moved off it is two more routes entries,
# because API Gateway matches the most specific route first: an explicit route always beats
# $default, and everything else falls through to the monolith unchanged.
#
# Moving the next domain is a two-line diff: add its function to integrations, add its two route
# keys to routes. Nothing about the monolith changes, so there is no window where a request has
# nowhere to go.
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api"
# with version = "~> 2.0"; the relative path here keeps the example runnable from the repository.

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

  # The domains already living outside the monolith. Adding a third is one entry here.
  migrated = ["posts", "users"]
}

# --- The functions ----------------------------------------------------------------------------
# The monolith and one function per migrated domain. In the real estate these are module
# "lambda-function" blocks and the images come from CI; here they are the smallest thing that runs.

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

resource "aws_lambda_function" "legacy" {
  function_name    = "${local.name}-api"
  role             = aws_iam_role.api.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 29
}

resource "aws_lambda_function" "domain" {
  for_each = toset(local.migrated)

  function_name    = "${local.name}-api-${each.key}"
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

  name        = "${local.name}-api"
  description = "Example ${local.name} API (strangler migration in progress)"

  integrations = merge(
    {
      legacy = {
        lambda_function_name = aws_lambda_function.legacy.function_name
        lambda_invoke_arn    = aws_lambda_function.legacy.invoke_arn
        timeout_milliseconds = 29000
      }
    },
    {
      for d in local.migrated : d => {
        lambda_function_name = aws_lambda_function.domain[d].function_name
        lambda_invoke_arn    = aws_lambda_function.domain[d].invoke_arn
        timeout_milliseconds = 29000
      }
    },
  )

  # The monolith holds everything not claimed below.
  default_integration = "legacy"

  # Two route keys per domain, and both are needed. "ANY /api/v1/posts" does not match
  # /api/v1/posts/123, and "ANY /api/v1/posts/{proxy+}" does not match the bare collection path.
  # Leave one out and half the domain's traffic quietly keeps hitting the monolith.
  routes = merge([
    for d in local.migrated : {
      "ANY /api/v1/${d}"          = { integration = d }
      "ANY /api/v1/${d}/{proxy+}" = { integration = d }
    }
  ]...)

  # Layer 1 of the rate limiting. The stage default covers $default and anything without an
  # override; the per-route entries are where a hot or expensive prefix gets its own ceiling.
  throttling_burst_limit = 200
  throttling_rate_limit  = 100

  route_settings = {
    # The monolith is the one nobody has load tested lately, so it gets the tighter limit.
    "$default" = {
      throttling_burst_limit = 100
      throttling_rate_limit  = 50
    }

    # Per-domain metrics only for the paths that have moved, so the migration is measurable without
    # paying for a metric dimension on every route.
    "ANY /api/v1/posts/{proxy+}" = {
      detailed_metrics_enabled = true
    }
    "ANY /api/v1/users/{proxy+}" = {
      detailed_metrics_enabled = true
    }
  }

  access_log_retention_days = 14
}

output "api_url" {
  description = "Origin the frontend calls. Unchanged by the migration, which is the point."
  value       = module.api.api_url
}

output "route_integrations" {
  description = "Which backend answers each route key. Read this in a plan to see how much of the monolith is left."
  value       = module.api.route_integrations
}

output "integration_ids" {
  description = "Integration ids keyed by backend name."
  value       = module.api.integration_ids
}
