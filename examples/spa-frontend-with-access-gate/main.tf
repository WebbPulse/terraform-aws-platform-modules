terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

variable "staging_access_gate" {
  description = "Turn the sign-in wall on. False reproduces a plain public staging site."
  type        = bool
  default     = true
}

variable "staging_access_users" {
  description = "Email addresses allowed through the gate."
  type        = list(string)
  default     = ["someone@example.com"]
}

locals {
  name     = "example-staging-frontend"
  domain   = "staging.example.com"
  www_host = "www.${local.domain}"
  api_host = "api.${local.domain}"
}

resource "aws_route53_zone" "staging" {
  name = local.domain
}

resource "aws_acm_certificate" "this" {
  provider = aws.us_east_1

  domain_name               = local.www_host
  subject_alternative_names = [local.domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.staging.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_cloudfront_function" "apex_redirect" {
  count = var.staging_access_gate ? 0 : 1

  name    = "${local.name}-apex-redirect"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = "function handler(event) { return appHandler(event); }\n${local.app_handler_js}"
}

locals {
  app_handler_js = <<-EOT
    function appHandler(event) {
      var host = event.request.headers.host ? event.request.headers.host.value : "";
      if (host === "${local.domain}") {
        return {
          statusCode: 301,
          statusDescription: "Moved Permanently",
          headers: { location: { value: "https://${local.www_host}" + event.request.uri } },
        };
      }
      return event.request;
    }
  EOT
}

module "gate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-access-gate"
  version = "~> 1.4"

  count = var.staging_access_gate ? 1 : 0

  name             = "example-staging"
  cookie_domain    = local.domain
  site_host        = local.www_host
  additional_hosts = [local.domain]
  allowed_emails   = var.staging_access_users

  viewer_request_handler_js = local.app_handler_js
}

module "frontend" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend"
  version = "~> 1.5"

  name = local.name

  aliases             = [local.www_host, local.domain]
  acm_certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  viewer_request_function_arn = one(aws_cloudfront_function.apex_redirect[*].arn)

  access_gate = var.staging_access_gate ? {
    key_group_id                                           = module.gate[0].key_group_id
    viewer_request_function_arn                            = module.gate[0].viewer_request_function_arn
    login_origin_domain_name                               = module.gate[0].login_origin_domain_name
    login_origin_access_control_id                         = module.gate[0].login_origin_access_control_id
    auth_path_pattern                                      = module.gate[0].auth_path_pattern
    cache_policy_id_caching_disabled                       = module.gate[0].cache_policy_id_caching_disabled
    origin_request_policy_id_all_viewer_except_host_header = module.gate[0].origin_request_policy_id_all_viewer_except_host_header
  } : null

  create_dns_records = true
  zone_id            = aws_route53_zone.staging.zone_id
  dns_records = {
    www  = local.www_host
    apex = local.domain
  }
}

output "frontend_url" {
  description = "Public HTTPS URL the site is served from, behind the access gate."
  value       = module.frontend.frontend_url
}

output "frontend_api_base_url" {
  description = "Base URL the frontend build calls. The API host directly, not a path on this distribution."
  value       = "https://${local.api_host}"
}

output "hosted_ui_domain" {
  description = "Where browsers are sent to sign in, null when the gate is off."
  value       = one(module.gate[*].hosted_ui_domain)
}
