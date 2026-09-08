# The staging shape: the same Lambda-backed HTTP API, switched behind the staging access gate when
# the workspace factory sets staging_access_gate = true. With the gate on, the execute-api endpoint
# is disabled and every route requires the gate's origin-verify authorizer, so the API answers only
# to the CloudFront distribution that adds the header. With the gate off, the plan is the plain API.
#
# The distribution side of the gate (login origin, key group, behaviors) is shown in
# examples/staging-access-gate-complete and is left out here.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # staging-access-gate requires >= 6.0; matching it here keeps the example honest about the
      # provider it actually runs on.
      version = ">= 6.0, < 7.0"
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

variable "staging_access_gate" {
  description = "Put the environment behind the access gate. Pushed to the staging workspace by WebbPulse-Platform."
  type        = bool
  default     = false
}

variable "staging_access_users" {
  description = "Email addresses allowed through the gate."
  type        = list(string)
  default     = []
}

locals {
  name        = "example-staging"
  domain_name = "staging.example.com"
  api_host    = "api.${local.domain_name}"
}

data "aws_route53_zone" "this" {
  name = local.domain_name
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
  timeout          = 15
}

# --- The certificate --------------------------------------------------------------------------

resource "aws_acm_certificate" "api" {
  domain_name       = local.api_host
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.api_cert_validation : r.fqdn]
}

# --- The gate ---------------------------------------------------------------------------------
# The two modules reference each other: the gate attaches its authorizer to module.api's API id,
# and module.api attaches that authorizer to its routes. Terraform resolves this at the resource
# level (api -> authorizer -> routes), so there is no cycle.

module "gate" {
  count  = var.staging_access_gate ? 1 : 0
  source = "../../modules/staging-access-gate"

  name           = local.name
  cookie_domain  = local.domain_name
  site_host      = "www.${local.domain_name}"
  allowed_emails = var.staging_access_users
  http_api_id    = module.api.api_id
}

# --- The API ----------------------------------------------------------------------------------

module "api" {
  source = "../../modules/http-api"

  name = "${local.name}-api"

  integrations = {
    legacy = {
      lambda_function_name = aws_lambda_function.api.function_name
      lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
    }
  }

  # $default catches everything, so there is no route on this API the gate's authorizer misses.
  default_integration = "legacy"

  throttling_burst_limit = 200
  throttling_rate_limit  = 100

  domain_name     = local.api_host
  certificate_arn = aws_acm_certificate_validation.api.certificate_arn
  zone_id         = data.aws_route53_zone.this.zone_id

  # authorizer_id is applied by the module to every route it creates, $default included. A route
  # is never written without an authorization_type, so the gate cannot be forgotten on one path.
  disable_execute_api_endpoint = var.staging_access_gate
  authorizer_id                = var.staging_access_gate ? module.gate[0].http_api_authorizer_id : null
}

output "api_url" {
  description = "Origin the frontend calls. Behind the gate, browsers reach it through the distribution instead."
  value       = module.api.api_url
}

output "origin_verify_ssm_parameter_name" {
  description = "Where a pipeline reads the header it needs to call api_url directly while the gate is on."
  value       = one(module.gate[*].origin_verify_ssm_parameter_name)
}
