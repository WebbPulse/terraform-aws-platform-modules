# A staging site behind the staging-access-gate module. The frontend module does all the
# distribution wiring the gate's consumer checklist asks for; the consumer passes the gate's
# outputs through as one object. Real consumers gate the access_gate argument on a variable so
# the production workspace passes null and plans a no-op.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
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

# The staging child zone lives in this account; its NS delegation from example.com is written by
# the parent zone's owner and is out of scope here.
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

# The application's own viewer-request logic, used directly when the gate is off. When the gate is
# on, the same code goes to the gate as viewer_request_handler_js and the gate's function wraps it.
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

# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------

module "gate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-access-gate"
  version = "~> 1.1"

  count = var.staging_access_gate ? 1 : 0

  name             = "example-staging"
  cookie_domain    = local.domain
  site_host        = local.www_host
  additional_hosts = [local.domain]
  allowed_emails   = var.staging_access_users

  viewer_request_handler_js = local.app_handler_js

  # cloudfront_distribution_arn stays unset: the distribution below consumes this module's
  # outputs, so naming it here would be a cycle. http_api_id and the route authorizer wiring are
  # shown in examples/staging-access-gate-complete.
}

# ---------------------------------------------------------------------------
# The site
# ---------------------------------------------------------------------------

module "frontend" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend"
  version = "~> 1.4"

  name = local.name

  aliases             = [local.www_host, local.domain]
  acm_certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  # Ignored while the gate is on; the gate's function takes over the viewer-request slot.
  viewer_request_function_arn = one(aws_cloudfront_function.apex_redirect[*].arn)

  access_gate = var.staging_access_gate ? {
    key_group_id                                           = module.gate[0].key_group_id
    viewer_request_function_arn                            = module.gate[0].viewer_request_function_arn
    login_origin_domain_name                               = module.gate[0].login_origin_domain_name
    login_origin_access_control_id                         = module.gate[0].login_origin_access_control_id
    auth_path_pattern                                      = module.gate[0].auth_path_pattern
    api_origin_domain_name                                 = local.api_host
    api_path_pattern                                       = module.gate[0].api_path_pattern
    origin_verify_header_name                              = module.gate[0].origin_verify_header_name
    cache_policy_id_caching_disabled                       = module.gate[0].cache_policy_id_caching_disabled
    origin_request_policy_id_all_viewer_except_host_header = module.gate[0].origin_request_policy_id_all_viewer_except_host_header
  } : null

  # The secret is its own input, not a member of access_gate: an object with one sensitive member
  # is sensitive as a whole at the module boundary, which would redact every path pattern and
  # origin id read out of it and make the distribution plan a spurious in-place update.
  access_gate_origin_verify_header_value = one(module.gate[*].origin_verify_header_value)

  create_dns_records = true
  zone_id            = aws_route53_zone.staging.zone_id
  dns_records = {
    www  = local.www_host
    apex = local.domain
  }
}

output "frontend_url" {
  value = module.frontend.frontend_url
}

output "hosted_ui_domain" {
  description = "Where browsers are sent to sign in, null when the gate is off."
  value       = one(module.gate[*].hosted_ui_domain)
}
