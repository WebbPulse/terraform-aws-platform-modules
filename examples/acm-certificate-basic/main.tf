variable "domain_name" {
  description = "Apex the site is served from."
  type        = string
  default     = "example.com"
}

variable "zone_id" {
  description = "Hosted zone for domain_name, in this account."
  type        = string
  default     = null
}

provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "site_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws.us_east_1
    aws.records = aws
  }

  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  zone_id                   = var.zone_id
}

module "api_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws
    aws.records = aws
  }

  domain_name = "api.${var.domain_name}"
  zone_id     = var.zone_id
}

output "site_certificate_arn" {
  description = "Hand this to the CloudFront distribution's viewer certificate."
  value       = module.site_certificate.certificate_arn
}

output "api_certificate_arn" {
  description = "Hand this to the API Gateway custom domain."
  value       = module.api_certificate.certificate_arn
}
