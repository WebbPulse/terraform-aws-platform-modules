variables {
  name_prefix        = "example-staging"
  issuer             = "https://api.staging.example.com/api/auth"
  audience           = "example-staging-api"
  registrable_domain = "staging.example.com"

  attach_role_policies = false
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

run "no_role_policies_when_the_policies_are_turned_off" {
  command = plan

  variables {
    attach_role_policies = false
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_signing) == 0 && length(aws_iam_role_policy.identity_tables) == 0
    error_message = "With attach_role_policies false the module must attach nothing and leave the caller to use the policy JSON outputs."
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_mfa) == 0
    error_message = "With attach_role_policies false the MFA grant must not be attached either."
  }

  assert {
    condition     = length(aws_kms_key.identity_signing) == 1
    error_message = "attach_role_policies false must still create the signing key; it governs the grants only."
  }
}

run "the_grants_count_off_the_boolean_and_not_the_role_name" {
  command = plan

  variables {
    attach_role_policies = false
    identity_role_name   = "example-staging-identity"
    identity_role_arn    = "arn:aws:iam::123456789012:role/example-staging-identity"
  }

  assert {
    condition = (
      length(aws_iam_role_policy.identity_signing) == 0 &&
      length(aws_iam_role_policy.identity_tables) == 0 &&
      length(aws_iam_role_policy.identity_mfa) == 0
    )
    error_message = "attach_role_policies false must win over a named role: the count must not read identity_role_name, or an unknown role id makes the plan undecidable."
  }
}

run "attaching_with_no_role_named_is_refused" {
  command = plan

  variables {
    attach_role_policies = true
    identity_role_name   = null
  }

  expect_failures = [
    var.identity_role_name,
  ]
}

run "the_role_gets_exactly_the_two_grants_the_identity_flows_need" {
  command = plan

  variables {
    identity_role_name   = "example-staging-identity"
    attach_role_policies = true
    identity_role_arn    = "arn:aws:iam::123456789012:role/example-staging-identity"
    signing_key_count    = 2
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_signing) == 1 && length(aws_iam_role_policy.identity_tables) == 1
    error_message = "Naming the role must attach both the signing grant and the table grant."
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_mfa) == 1
    error_message = "Naming the role must also attach the MFA envelope grant, since the key defaults on."
  }

  assert {
    condition     = contains(local.mfa_key_actions, "kms:GenerateDataKey") && contains(local.mfa_key_actions, "kms:Decrypt")
    error_message = "The envelope grant must allow kms:GenerateDataKey for sealing a seed and kms:Decrypt for opening one."
  }

  assert {
    condition     = length(local.mfa_key_actions) == 2
    error_message = "The envelope grant must be exactly those two actions: crypto.py calls GenerateDataKey and Decrypt and nothing else."
  }

  assert {
    condition     = !contains(local.mfa_key_actions, "kms:Encrypt")
    error_message = "kms:Encrypt must not be granted: the design is an envelope, so the plaintext seed never reaches KMS."
  }

  assert {
    condition     = length(setsubtract(local.mfa_key_actions, ["kms:GenerateDataKey", "kms:Decrypt"])) == 0
    error_message = "The key policy and the role policy are built from the same action list, so neither half can be wider than the other."
  }

  assert {
    condition     = contains(keys(local.mfa_policy_statement.Condition.StringEquals), "kms:EncryptionContext:purpose")
    error_message = "The envelope grant must condition on the encryption context purpose, which is the half of the context that has a fixed value."
  }

  assert {
    condition     = keys(local.mfa_policy_statement.Condition)[0] == "StringEquals" && length(keys(local.mfa_policy_statement.Condition)) == 1
    error_message = "The encryption context condition must use StringEquals and nothing else: the condition key is single valued and a set operator on it is overly permissive."
  }

  assert {
    condition     = local.mfa_policy_statement.Condition.StringEquals["kms:EncryptionContext:purpose"] == "totp"
    error_message = "The pinned purpose must be totp, which is crypto.TOTP_ENCRYPTION_PURPOSE and what the package sends on every call."
  }

  assert {
    condition     = contains(local.signing_actions, "kms:Sign") && contains(local.signing_actions, "kms:GetPublicKey")
    error_message = "The signing grant must allow kms:Sign for issuing tokens and kms:GetPublicKey for building the JWKS."
  }

  assert {
    condition     = length([for a in local.signing_actions : a if length(regexall("^kms:(Create|Schedule|Disable|Delete|Put|Decrypt|Encrypt)", a)) > 0]) == 0
    error_message = "The signing grant must not include key management or encryption actions: the identity function signs and reads public keys, nothing else."
  }

  assert {
    condition     = length(local.signing_key_arns) == 2
    error_message = "The signing grant must cover every signing key, because the JWKS publishes the public half of all of them."
  }

  assert {
    condition     = length(local.table_policy_resources) == 2 * length(local.table_arns_list)
    error_message = "The table grant must cover indexes as well as tables: the family revocation query reads family_id-generation-index and a table-only policy denies it."
  }

  assert {
    condition     = !contains(var.table_policy_actions, "dynamodb:Scan")
    error_message = "The table grant must not include Scan: no identity flow scans, and granting it invites one that does."
  }

  assert {
    condition     = contains(var.table_policy_actions, "dynamodb:GetItem") && contains(var.table_policy_actions, "dynamodb:Query")
    error_message = "The table grant must allow the item level reads the identity flows actually make."
  }
}

run "the_environment_map_is_what_identity_settings_parses" {
  command = plan

  variables {
    signing_key_count  = 2
    active_signing_key = 1
  }

  assert {
    condition     = local.identity_environment["IDENTITY_ISSUER"] == var.issuer
    error_message = "IDENTITY_ISSUER must be the same string the authorizer validates."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_AUDIENCE"] == var.audience
    error_message = "IDENTITY_AUDIENCE must be the same string the authorizer requires."
  }

  assert {
    condition     = length(local.signing_key_arns) == 2
    error_message = "IDENTITY_SIGNING_KEY_ARNS must hold every signing key, because the JWKS publishes the public half of all of them."
  }

  assert {
    condition     = local.signing_key_order[0] == var.active_signing_key
    error_message = "The active signer must be first in the serialised list, because the package signs with signing_key_arns[0]."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_COOKIE_DOMAIN"] == var.registrable_domain
    error_message = "The refresh cookie is scoped to the registrable domain so subdomains share the session."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_RP_ID"] == var.registrable_domain
    error_message = "The WebAuthn RP ID is the registrable domain, and it is hashed into every credential for that credential's life."
  }

  assert {
    condition     = contains(keys(local.identity_environment), "IDENTITY_DATA_KEY_ARN")
    error_message = "With the envelope key on by default, IDENTITY_DATA_KEY_ARN must be in the map: it is IdentitySettings.data_key_arn and TOTP enrolment refuses without it."
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_PRODUCT_NAME") && !contains(keys(local.identity_environment), "IDENTITY_FRONTEND_BASE_URL")
    error_message = "The map must hold only variables that follow from this module's own resources; product strings belong to the consumer."
  }
}

run "no_additional_grants_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.additional_table_grants) == 0
    error_message = "additional_table_grants defaults to an empty map, so an existing consumer that does not set it must plan no new resource at all."
  }
}

run "an_additional_grant_reaches_only_the_tables_it_names" {
  command = plan

  variables {
    additional_table_grants = {
      users-credentials = {
        role_name = "example-staging-users"
        tables    = ["credentials"]
      }
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.additional_table_grants) == 1
    error_message = "One entry must attach exactly one inline policy."
  }

  assert {
    condition     = aws_iam_role_policy.additional_table_grants["users-credentials"].name == "identity-tables-users-credentials"
    error_message = "The policy name must carry the map key, so two grants on the same role do not collide on one inline policy name."
  }

  assert {
    condition     = aws_iam_role_policy.additional_table_grants["users-credentials"].role == "example-staging-users"
    error_message = "The grant must attach to the role the entry names, which is a different role from identity_role_name."
  }

  assert {
    condition     = length(local.additional_grant_resources["users-credentials"]) == 2
    error_message = "One table must produce two resources, the table and its index wildcard, the same shape the identity table grant takes. A table-only policy denies a Query against an index."
  }

  assert {
    condition     = length(local.additional_grant_resources["users-credentials"]) < length(local.table_policy_resources)
    error_message = "A grant naming one table must be narrower than the identity function's grant over every table, which is the point of naming tables rather than granting the set."
  }
}

run "an_additional_grant_takes_the_module_actions_unless_it_names_its_own" {
  command = plan

  variables {
    additional_table_grants = {
      broad = {
        role_name = "example-staging-users"
        tables    = ["credentials"]
      }
      narrow = {
        role_name = "example-staging-users"
        tables    = ["credentials"]
        actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
      }
    }
  }

  assert {
    condition     = coalesce(var.additional_table_grants["broad"].actions, var.table_policy_actions) == var.table_policy_actions
    error_message = "A grant with no actions must take table_policy_actions, so it never exceeds what the identity function itself is allowed."
  }

  assert {
    condition     = coalesce(var.additional_table_grants["narrow"].actions, var.table_policy_actions) == tolist(["dynamodb:GetItem", "dynamodb:PutItem"])
    error_message = "A grant that names actions must take exactly those, which is how a consumer gives a second role less than the identity function has."
  }

  assert {
    condition     = length(aws_iam_role_policy.additional_table_grants) == 2
    error_message = "Two entries must attach two policies, and the map key keeps their inline policy names distinct on the one role."
  }
}

run "a_grant_naming_a_table_the_module_does_not_create_is_refused" {
  command = plan

  variables {
    additional_table_grants = {
      typo = {
        role_name = "example-staging-users"
        tables    = ["credential"]
      }
    }
  }

  expect_failures = [
    var.additional_table_grants,
  ]
}

run "a_grant_naming_no_tables_is_refused" {
  command = plan

  variables {
    additional_table_grants = {
      empty = {
        role_name = "example-staging-users"
        tables    = []
      }
    }
  }

  expect_failures = [
    var.additional_table_grants,
  ]
}

run "a_grant_with_an_empty_actions_list_is_refused" {
  command = plan

  variables {
    additional_table_grants = {
      empty-actions = {
        role_name = "example-staging-users"
        tables    = ["credentials"]
        actions   = []
      }
    }
  }

  expect_failures = [
    var.additional_table_grants,
  ]
}
