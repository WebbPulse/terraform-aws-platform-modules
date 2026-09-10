# A product's whole identity layer in one module block: the KMS signing key the tokens are signed
# with, the symmetric KMS key TOTP seeds are sealed under, the six DynamoDB tables the identity
# flows read and write, the three IAM grants that let the identity function reach all of them, and
# the environment variables that configure the package.
#
# The JWT authorizer is deliberately left out of this example. Creating one is a second apply, for
# a reason worth understanding before copying this: see the ordering section below.

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

  # The registrable domain rather than the API host, so www and any future subdomain share the
  # refresh cookie and a passkey registered on one works on the others.
  registrable_domain = local.production ? "example.com" : "staging.example.com"
}

# The identity function's role. In a real configuration this is the role of the Lambda that serves
# /api/auth, usually module.lambda_domain["identity"].
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

  # These three strings are the identity contract, and each one is close to irreversible in its own
  # way.
  #
  # The issuer is byte identical in three places at once: the iss claim the function signs, the
  # issuer member of the discovery document, and the issuer the authorizer validates. The /api/auth
  # path is not cosmetic, because API Gateway appends /.well-known/openid-configuration to whatever
  # it is given.
  issuer = "https://${local.api_host}/api/auth"

  # Carrying the environment in the audience is what stops a staging token being accepted by
  # production.
  audience = "${local.prefix}-api"

  # Hashed into every passkey by the authenticator and immutable for that credential's life:
  # changing it later invalidates every passkey already registered.
  registrable_domain = local.registrable_domain

  # The role gets kms:Sign and kms:GetPublicKey on the signing keys, and item level access to the
  # four tables and their indexes. Both are needed; neither grants anything else.
  identity_role_name = aws_iam_role.identity.name
  identity_role_arn  = aws_iam_role.identity.arn

  # One key is the steady state. A rotation raises this to 2, deploys, then moves
  # active_signing_key to 1 and deploys again. Never both in one apply: the second apply would sign
  # with a key no verifier has fetched yet.
  signing_key_count  = 1
  active_signing_key = 0

  # Production gets continuous backups and tables AWS refuses to delete, so a staging environment
  # can still be torn down and rebuilt. The login-attempts table opts out of backups in both,
  # because its rows are failure counters inside a lookback window rather than state.
  point_in_time_recovery = true
  deletion_protection    = local.production
}

# The identity function's environment.
#
# The module's map is merged last so it wins over anything above it, and it holds only the
# variables that follow from its own resources: the issuer, the audience, the signing key ARNs, the
# cookie domain and the RP ID. The product strings around it have no resource behind them, so the
# module has no business inventing them.
locals {
  identity_environment = merge(
    {
      IDENTITY_ENVIRONMENT       = var.environment
      IDENTITY_PRODUCT_NAME      = "Example"
      IDENTITY_RP_NAME           = "Example"
      IDENTITY_SUPPORT_EMAIL     = "support@example.com"
      IDENTITY_FRONTEND_BASE_URL = local.production ? "https://example.com" : "https://staging.example.com"

      # The application reads table names from the environment rather than rebuilding them from a
      # prefix, so renaming the prefix never needs a matching change in the code.
      IDENTITY_TABLE_NAMES = jsonencode(module.identity.table_names)
    },
    module.identity.identity_environment,
  )
}

# ---------------------------------------------------------------------------
# The authorizer, and why it is a second apply
# ---------------------------------------------------------------------------
#
# Passing http_api_id creates a JWT authorizer on that API. It is left out here because
# CreateAuthorizer validates the issuer synchronously: API Gateway fetches
# <issuer>/.well-known/openid-configuration during the create call and fails the apply with
# BadRequestException when it does not get a document back. On the first apply of a new environment
# nothing is serving that URL yet, so the authorizer cannot be created in the same apply that
# creates the function that would serve it.
#
# Once the identity function is deployed and the two .well-known routes answer anonymously, add:
#
#     http_api_id = module.api.api_id
#
#     # What must already exist and already answer. Nothing the authorizer references implies that
#     # the routes serving the discovery document exist, so this is how that is expressed.
#     authorizer_depends_on = [module.api, module.lambda_domain]
#
# and the module polls the discovery URL until it answers before creating the authorizer, so a
# cold start or an asynchronous stage deployment does not fail the apply.
#
# The module does not attach the authorizer to any route, and that is deliberate rather than an
# omission: a route naming the authorizer must be created after it, while the .well-known routes
# must be created before it. One for_each cannot express both orderings, and Terraform refuses the
# resulting graph. So the module hands back authorizer_id and the caller attaches it.

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
