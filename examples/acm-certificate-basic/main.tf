# The single-account shape. One certificate for CloudFront, which ACM will only issue in
# us-east-1, and one regional certificate for the API Gateway custom domain, both validated in a
# hosted zone the same account owns. The zone is in the same account as both certificates, so the
# same provider goes to aws and aws.records; only the region differs between the two module calls.

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

# CloudFront reads certificates from us-east-1 and nowhere else.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# Covers the apex and everything under it. ACM proves both with one CNAME, so the two covered
# domains produce two record resources holding identical values, which is why allow_overwrite
# defaults to true.
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
