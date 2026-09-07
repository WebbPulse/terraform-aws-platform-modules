# A Lambda function served at https://api.example.com through an HTTP API. The function, its
# certificate and the hosted zone belong to the consumer; the module owns the API, its stage,
# access log, routes, invoke permission, custom domain, mapping and the alias record.
#
# This is the single-integration shape, the 2.0 equivalent of what 1.x did with lambda_invoke_arn:
# one backend named "legacy" and default_integration pointing at it, so $default carries everything.
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
  name        = "example-production"
  domain_name = "example.com"
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
  timeout          = 29
}

# --- The certificate, validated in the same zone ---------------------------------------------
# The module takes an issued certificate ARN rather than creating the certificate itself, because
# the validation records are written by whichever provider can reach the zone. Here that is the
# default provider; a consumer whose zone lives in another account uses a provider alias.

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

# --- The API ----------------------------------------------------------------------------------

module "api" {
  source = "../../modules/http-api"

  name        = "${local.name}-api"
  description = "Example ${local.name} API (Lambda proxy)"

  # One backend. Naming it "legacy" is what lets the module's own moved blocks take over a 1.x
  # integration and permission without destroying either.
  integrations = {
    legacy = {
      lambda_function_name = aws_lambda_function.api.function_name
      lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
      timeout_milliseconds = 29000
    }
  }

  default_integration = "legacy"

  # Layer 1 of the rate limiting: the stage's default route settings cover every route.
  throttling_burst_limit    = 50
  throttling_rate_limit     = 25
  access_log_retention_days = 14

  # Pass the validation's certificate_arn, not the certificate's arn, so the custom domain is
  # created only after the certificate is issued.
  domain_name     = local.api_host
  certificate_arn = aws_acm_certificate_validation.api.certificate_arn
  zone_id         = data.aws_route53_zone.this.zone_id
}

output "api_url" {
  description = "Origin the frontend calls."
  value       = module.api.api_url
}

output "api_endpoint" {
  description = "The execute-api endpoint, still live next to the custom domain."
  value       = module.api.api_endpoint
}
