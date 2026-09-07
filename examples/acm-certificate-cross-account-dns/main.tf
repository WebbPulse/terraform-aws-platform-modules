# The cross-account shape. The certificate is issued in this account, but the hosted zone that
# proves it belongs to another one, so the validation records are written through a provider that
# assumes a Route 53 write role there. That split is the reason the module takes two provider
# configurations instead of one: aws decides where the certificate lives, aws.records decides where
# the proof is written, and they are only the same account some of the time.
#
# It also shows the staging variant, where the zone is a delegated child this account owns. The
# certificate must not be validated until the delegation exists in the parent, or ACM asks the
# parent's resolvers for a record they have never heard of. depends_on cannot name an output, so
# the consumer depends on the whole module.

variable "environment" {
  description = "production or staging"
  type        = string
  default     = "production"
}

variable "parent_zone_id" {
  description = "Hosted zone for example.com, owned by the account route53_write_role_arn points into. Used in production, where the records go cross-account."
  type        = string
  default     = null
}

variable "route53_write_role_arn" {
  description = "Role in the account that owns the parent zone, allowed to write records into it. Empty writes with this workspace's own credentials."
  type        = string
  default     = ""
}

locals {
  production = var.environment == "production"
  domain     = local.production ? "example.com" : "staging.example.com"

  # Only production reaches across accounts. Staging owns its delegated child zone outright, so
  # its records provider assumes nothing.
  dns_role_arn = local.production ? var.route53_write_role_arn : ""
}

provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# Where the validation records go. The assume_role stays dynamic so one configuration covers both
# environments.
provider "aws" {
  alias  = "dns"
  region = "us-west-2"

  dynamic "assume_role" {
    for_each = local.dns_role_arn == "" ? [] : [local.dns_role_arn]

    content {
      role_arn = assume_role.value
    }
  }
}

# Staging owns a delegated child zone; production writes into the parent directly.
module "staging_dns" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-dns"
  version = "~> 1.6"

  providers = {
    aws        = aws
    aws.parent = aws.dns
  }

  enabled        = !local.production
  zone_name      = local.domain
  parent_zone_id = var.parent_zone_id
}

locals {
  records_zone_id = local.production ? var.parent_zone_id : module.staging_dns.zone_id
}

module "site_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws.us_east_1
    aws.records = aws.dns
  }

  domain_name               = "www.${local.domain}"
  subject_alternative_names = [local.domain]
  zone_id                   = local.records_zone_id

  # Staging must not try to validate before its delegation is live in the parent zone.
  depends_on = [module.staging_dns]
}

module "api_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws
    aws.records = aws.dns
  }

  domain_name = "api.${local.domain}"
  zone_id     = local.records_zone_id

  depends_on = [module.staging_dns]
}

output "site_certificate_arn" {
  description = "Issued certificate for www and the apex, ready for CloudFront."
  value       = module.site_certificate.certificate_arn
}

output "api_certificate_arn" {
  description = "Issued regional certificate for the API Gateway custom domain."
  value       = module.api_certificate.certificate_arn
}
