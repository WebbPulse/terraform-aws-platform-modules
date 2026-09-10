# The authorizer, the two IAM grants, and the environment map.
#
# The authorizer runs are plan only, which means they check the arguments Terraform will send to
# CreateAuthorizer and not whether the call succeeds. The part that actually fails in practice, API
# Gateway synchronously fetching the discovery document, cannot be reached from a test with a
# mocked provider; it is covered by authorizer_depends_on and the discovery poll instead.

variables {
  name_prefix        = "example-staging"
  issuer             = "https://api.staging.example.com/api/auth"
  audience           = "example-staging-api"
  registrable_domain = "staging.example.com"
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

# The KMS key policy names the account root, which means a real GetCallerIdentity call. A mocked
# provider has no credentials to make one, so the account id and partition are supplied here. They
# are the only values the module reads from either data source.
override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

# The default is no authorizer, because the first apply of a new environment happens before the
# identity function is serving anything and CreateAuthorizer would fail.
run "no_authorizer_without_an_api_id" {
  command = plan

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt) == 0
    error_message = "The authorizer must be opt-in: on a first apply nothing is serving the discovery document yet and CreateAuthorizer would fail the whole apply."
  }

  assert {
    condition     = length(terraform_data.discovery_document_ready) == 0
    error_message = "With no authorizer to order there is nothing to wait for, so the poll must not run."
  }
}

run "the_authorizer_validates_the_same_issuer_and_audience_the_signer_stamps" {
  command = plan

  variables {
    http_api_id                 = "abcd1234"
    wait_for_discovery_document = false
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt) == 1
    error_message = "An http_api_id must create the JWT authorizer."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].authorizer_type == "JWT"
    error_message = "A JWT authorizer verifies the signature in the gateway, which is the point: an unauthenticated request never reaches the function."
  }

  # Both come from the same module inputs the identity function is configured from, so the gateway
  # and the signer cannot drift apart. A mismatch denies every request and logs no reason.
  assert {
    condition     = one(aws_apigatewayv2_authorizer.identity_jwt[0].jwt_configuration).issuer == var.issuer
    error_message = "The authorizer's issuer must be byte identical to the iss claim the function stamps."
  }

  assert {
    condition     = one(aws_apigatewayv2_authorizer.identity_jwt[0].jwt_configuration).audience == toset([var.audience])
    error_message = "The authorizer must require exactly the module's audience by default, so a staging token is not accepted by production."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].identity_sources == toset(["$request.header.Authorization"])
    error_message = "The bearer token belongs in the Authorization header, which is what every client already sends."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].name == "example-staging-identity-jwt"
    error_message = "The authorizer name defaults to <name_prefix>-identity-jwt."
  }
}

# The wait is what turns a race into a bounded, self-explaining failure, so it must be on unless a
# consumer deliberately turns it off.
run "the_discovery_poll_runs_by_default_alongside_the_authorizer" {
  command = plan

  variables {
    http_api_id = "abcd1234"
  }

  assert {
    condition     = length(terraform_data.discovery_document_ready) == 1
    error_message = "wait_for_discovery_document defaults true: without it a spurious CreateAuthorizer failure and a real misconfiguration look identical."
  }

  assert {
    condition     = terraform_data.discovery_document_ready[0].triggers_replace.issuer == var.issuer
    error_message = "The poll must re-run when the issuer changes, since what it asserts is that this exact URL answers."
  }
}

run "extra_audiences_replace_the_default_when_given" {
  command = plan

  variables {
    http_api_id                 = "abcd1234"
    wait_for_discovery_document = false
    authorizer_audiences        = ["example-staging-api", "example-staging-admin"]
  }

  assert {
    condition     = one(aws_apigatewayv2_authorizer.identity_jwt[0].jwt_configuration).audience == toset(["example-staging-api", "example-staging-admin"])
    error_message = "authorizer_audiences must replace the single-audience default outright."
  }
}

# ---------------------------------------------------------------------------
# The grants
# ---------------------------------------------------------------------------

run "no_role_policies_when_no_role_was_named" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.identity_signing) == 0 && length(aws_iam_role_policy.identity_tables) == 0
    error_message = "With identity_role_name null the module must attach nothing and leave the caller to use the policy JSON outputs."
  }
}

run "the_role_gets_exactly_the_two_grants_the_identity_flows_need" {
  command = plan

  variables {
    identity_role_name = "example-staging-identity"
    identity_role_arn  = "arn:aws:iam::123456789012:role/example-staging-identity"
    signing_key_count  = 2
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_signing) == 1 && length(aws_iam_role_policy.identity_tables) == 1
    error_message = "Naming the role must attach both the signing grant and the table grant."
  }

  # Sign and GetPublicKey and nothing else. The function never needs to manage the key, and
  # kms:Decrypt on a signing key is meaningless.
  assert {
    condition     = contains(local.signing_actions, "kms:Sign") && contains(local.signing_actions, "kms:GetPublicKey")
    error_message = "The signing grant must allow kms:Sign for issuing tokens and kms:GetPublicKey for building the JWKS."
  }

  assert {
    condition     = length([for a in local.signing_actions : a if length(regexall("^kms:(Create|Schedule|Disable|Delete|Put|Decrypt|Encrypt)", a)) > 0]) == 0
    error_message = "The signing grant must not include key management or encryption actions: the identity function signs and reads public keys, nothing else."
  }

  # Both keys, not only the active one. The function fetches the public half of every key in the
  # list to build the JWKS, so a grant covering only the signer breaks the JWKS during a rotation.
  assert {
    condition     = length(local.signing_key_arns) == 2
    error_message = "The signing grant must cover every signing key, because the JWKS publishes the public half of all of them."
  }

  # Not optional: the refresh token family query reads family_id-generation-index, and a policy
  # naming only table ARNs denies it with an AccessDenied that points at the table.
  # The ARN strings are unknown until apply, so what is checkable at plan is the shape: one table
  # entry plus one index entry for every table. A table-only policy would be half this length.
  assert {
    condition     = length(local.table_policy_resources) == 2 * length(local.table_arns_list)
    error_message = "The table grant must cover indexes as well as tables: the family revocation query reads family_id-generation-index and a table-only policy denies it."
  }

  # No Scan, deliberately. No identity flow scans a table, and granting it invites one that does.
  assert {
    condition     = !contains(var.table_policy_actions, "dynamodb:Scan")
    error_message = "The table grant must not include Scan: no identity flow scans, and granting it invites one that does."
  }

  assert {
    condition     = contains(var.table_policy_actions, "dynamodb:GetItem") && contains(var.table_policy_actions, "dynamodb:Query")
    error_message = "The table grant must allow the item level reads the identity flows actually make."
  }
}

# ---------------------------------------------------------------------------
# The environment map
# ---------------------------------------------------------------------------

run "the_environment_map_is_what_identity_settings_parses" {
  command = plan

  variables {
    signing_key_count  = 2
    active_signing_key = 1
  }

  # Every name here is a field of webbpulse.identity.IdentitySettings, whose env_prefix is
  # IDENTITY_, so the composition root builds the settings object straight from the environment.
  assert {
    condition     = local.identity_environment["IDENTITY_ISSUER"] == var.issuer
    error_message = "IDENTITY_ISSUER must be the same string the authorizer validates."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_AUDIENCE"] == var.audience
    error_message = "IDENTITY_AUDIENCE must be the same string the authorizer requires."
  }

  # A JSON array rather than a comma separated string: the settings field is a list and pydantic
  # parses list fields as JSON, so a CSV value fails to parse at import time.
  assert {
    condition     = length(local.signing_key_arns) == 2
    error_message = "IDENTITY_SIGNING_KEY_ARNS must hold every signing key, because the JWKS publishes the public half of all of them."
  }

  assert {
    condition     = local.signing_key_order[0] == var.active_signing_key
    error_message = "The active signer must be first in the serialised list, because the package signs with signing_key_arns[0]."
  }

  # The cookie is scoped to the registrable domain so www and any future subdomain share it, and
  # the RP ID is the same value because a passkey is bound to it for life.
  assert {
    condition     = local.identity_environment["IDENTITY_COOKIE_DOMAIN"] == var.registrable_domain
    error_message = "The refresh cookie is scoped to the registrable domain so subdomains share the session."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_RP_ID"] == var.registrable_domain
    error_message = "The WebAuthn RP ID is the registrable domain, and it is hashed into every credential for that credential's life."
  }

  # Product strings this module has no resource behind are deliberately absent, so a consumer
  # merging its own block on top is not fighting an invented default.
  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_PRODUCT_NAME") && !contains(keys(local.identity_environment), "IDENTITY_FRONTEND_BASE_URL")
    error_message = "The map must hold only variables that follow from this module's own resources; product strings belong to the consumer."
  }
}
