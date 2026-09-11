variable "environment" {
  description = "production or staging"
  type        = string
  default     = "staging"
}

provider "aws" {
  region = "us-west-2"
}

locals {
  prefix     = "example-${var.environment}"
  production = var.environment == "production"

  api_host = local.production ? "api.example.com" : "api.staging.example.com"

  registrable_domain = local.production ? "example.com" : "staging.example.com"
}

resource "aws_iam_role" "identity" {
  name = "${local.prefix}-identity"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

module "identity" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/identity"
  version = "~> 2.7"

  name_prefix = local.prefix

  issuer = "https://${local.api_host}/api/auth"

  audience = "${local.prefix}-api"

  registrable_domain = local.registrable_domain

  identity_role_name = aws_iam_role.identity.name
  identity_role_arn  = aws_iam_role.identity.arn

  signing_key_count  = 1
  active_signing_key = 0

  point_in_time_recovery = true
  deletion_protection    = local.production
}

locals {
  identity_environment = merge(
    {
      IDENTITY_ENVIRONMENT       = var.environment
      IDENTITY_PRODUCT_NAME      = "Example"
      IDENTITY_RP_NAME           = "Example"
      IDENTITY_SUPPORT_EMAIL     = "support@example.com"
      IDENTITY_FRONTEND_BASE_URL = local.production ? "https://example.com" : "https://staging.example.com"

      IDENTITY_TABLE_NAMES = jsonencode(module.identity.table_names)
    },
    module.identity.identity_environment,
  )
}

output "identity_environment" {
  description = "The identity function's environment block, ready to pass to a Lambda."
  value       = local.identity_environment
}

output "table_names" {
  description = "Logical name to full table name for the four identity tables."
  value       = module.identity.table_names
}

output "signing_key_alias" {
  description = "Alias of the active signing key. KMS accepts it anywhere it accepts a key id."
  value       = module.identity.signing_key_alias
}
