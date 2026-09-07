# A production-shaped site: private bucket, CloudFront, www plus apex on a certificate the
# consumer validates in us-east-1, an apex to www redirect function, and alias records written by
# the module into a zone in the same account.

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

# CloudFront only accepts certificates from us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

locals {
  name     = "example-production-frontend"
  domain   = "example.com"
  www_host = "www.${local.domain}"
}

data "aws_route53_zone" "this" {
  name = local.domain
}

# ---------------------------------------------------------------------------
# Certificate. The module takes the validated ARN; it never creates certificates itself because
# the validation records land in a zone whose owner differs per consumer.
# ---------------------------------------------------------------------------

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

  zone_id         = data.aws_route53_zone.this.zone_id
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

# ---------------------------------------------------------------------------
# Application viewer-request logic stays with the consumer.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_function" "apex_redirect" {
  name    = "${local.name}-apex-redirect"
  runtime = "cloudfront-js-2.0"
  publish = true

  code = <<-EOT
    async function handler(event) {
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
# The site
# ---------------------------------------------------------------------------

module "frontend" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend"
  version = "~> 1.2"

  name = local.name

  aliases             = [local.www_host, local.domain]
  acm_certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  viewer_request_function_arn = aws_cloudfront_function.apex_redirect.arn

  # AWS managed policies: CachingOptimized (the default), CORS-S3Origin, SecurityHeadersPolicy.
  origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
  response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"

  create_dns_records = true
  zone_id            = data.aws_route53_zone.this.zone_id
  dns_records = {
    www  = local.www_host
    apex = local.domain
  }
}

output "frontend_url" {
  value = module.frontend.frontend_url
}

output "deploy_targets" {
  description = "What a deploy pipeline needs: the bucket to sync and the distribution to invalidate."
  value = {
    bucket          = module.frontend.bucket_name
    distribution_id = module.frontend.distribution_id
  }
}
