# A staging workspace that owns staging.example.com and delegates it from example.com, which lives
# in another account. The workspace's own credentials create the child zone; the NS record in the
# parent is written through a second provider configuration that assumes a narrowly scoped Route 53
# write role in the parent's account. The production workspace of the same application sets
# enabled = false and the module plans nothing.

variable "environment" {
  description = "production or staging"
  type        = string
  default     = "staging"
}

variable "parent_zone_id" {
  description = "Hosted zone id of example.com in the account that owns it."
  type        = string
  default     = null
}

variable "route53_write_role_arn" {
  description = "Role in the parent account allowed to change the NS record for staging.example.com. null means the run credentials write to the parent zone directly."
  type        = string
  default     = null
}

locals {
  staging   = var.environment == "staging"
  zone_name = local.staging ? "staging.example.com" : "example.com"
}

provider "aws" {
  region = "us-west-2"
}

# Only used for the delegation record. Keep the assume_role dynamic so the same configuration
# works where no cross-account role is needed.
provider "aws" {
  alias  = "parent_dns"
  region = "us-west-2"

  dynamic "assume_role" {
    for_each = var.route53_write_role_arn == null ? [] : [var.route53_write_role_arn]

    content {
      role_arn = assume_role.value
    }
  }
}

module "staging_dns" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-dns"
  version = "~> 1.2"

  providers = {
    aws        = aws
    aws.parent = aws.parent_dns
  }

  enabled        = local.staging
  zone_name      = local.zone_name
  parent_zone_id = var.parent_zone_id
}

# Certificate validation must wait for the delegation, otherwise ACM asks the parent's resolvers
# for a record they do not know about yet. depends_on cannot name an output, so depend on the
# module: it holds nothing but the zone and the delegation.
resource "aws_acm_certificate" "site" {
  count = local.staging ? 1 : 0

  domain_name       = local.zone_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = local.staging ? toset([local.zone_name]) : toset([])

  zone_id         = module.staging_dns.zone_id
  name            = one([for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.resource_record_name if dvo.domain_name == each.key])
  type            = one([for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.resource_record_type if dvo.domain_name == each.key])
  ttl             = 60
  records         = [one([for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.resource_record_value if dvo.domain_name == each.key])]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  count = local.staging ? 1 : 0

  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]

  depends_on = [module.staging_dns]
}

output "staging_zone_name_servers" {
  description = "What the parent's NS record points at; null in production."
  value       = module.staging_dns.name_servers
}
