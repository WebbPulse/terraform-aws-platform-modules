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

run "the_envelope_key_is_created_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.identity_mfa) == 1
    error_message = "enable_mfa_encryption_key defaults to true: a product with TOTP on and no key stores nothing, because EnvelopeCipher refuses to construct without one."
  }

  assert {
    condition     = aws_kms_key.identity_mfa[0].customer_master_key_spec == "SYMMETRIC_DEFAULT"
    error_message = "The envelope key must be SYMMETRIC_DEFAULT: GenerateDataKey is not available on an asymmetric key."
  }

  assert {
    condition     = aws_kms_key.identity_mfa[0].key_usage == "ENCRYPT_DECRYPT"
    error_message = "The envelope key must be ENCRYPT_DECRYPT; a SIGN_VERIFY key cannot wrap a data key."
  }

  assert {
    condition     = aws_kms_key.identity_mfa[0].enable_key_rotation
    error_message = "Automatic rotation must default on for the envelope key: unlike the signing key it has no material-derived identifier, so rotating it orphans nothing."
  }

  assert {
    condition     = !aws_kms_key.identity_signing[0].enable_key_rotation
    error_message = "The signing key must still have rotation off: its kid is derived from the key material, so rotating it orphans every already-issued token."
  }

  assert {
    condition     = aws_kms_key.identity_mfa[0].deletion_window_in_days == 30
    error_message = "The deletion window must default to the 30 day maximum: deleting this key makes every stored TOTP seed permanently unreadable."
  }

  assert {
    condition     = aws_kms_key.identity_mfa[0].key_usage != aws_kms_key.identity_signing[0].key_usage
    error_message = "The envelope key and the signing key must be different keys with different usages, so a compromise of either is bounded."
  }
}

run "the_alias_is_a_pure_function_of_the_name_prefix" {
  command = plan

  assert {
    condition     = aws_kms_alias.identity_mfa[0].name == "alias/example-staging-identity-mfa"
    error_message = "The alias name must be alias/<name_prefix>-identity-mfa, so a consumer can pass it where KMS accepts a key id without taking a resource reference."
  }

  assert {
    condition     = aws_kms_alias.identity_mfa[0].name != aws_kms_alias.identity_signing[0].name
    error_message = "The envelope alias must not collide with the signing alias: an alias is unique per account and region."
  }
}

run "the_alias_can_be_turned_off_without_losing_the_key" {
  command = plan

  variables {
    create_mfa_encryption_key_alias = false
  }

  assert {
    condition     = length(aws_kms_alias.identity_mfa) == 0
    error_message = "create_mfa_encryption_key_alias = false must create no alias, for an account where something else owns the name."
  }

  assert {
    condition     = length(aws_kms_key.identity_mfa) == 1
    error_message = "Turning the alias off must not turn the key off: the package reads the ARN, not the alias."
  }
}

run "the_envelope_key_can_be_turned_off_entirely" {
  command = plan

  variables {
    enable_mfa_encryption_key = false
    identity_role_name        = "example-staging-identity"
    attach_role_policies      = true
    identity_role_arn         = "arn:aws:iam::123456789012:role/example-staging-identity"
  }

  assert {
    condition     = length(aws_kms_key.identity_mfa) == 0
    error_message = "enable_mfa_encryption_key = false must create no key, for a product running with TOTP disabled outright."
  }

  assert {
    condition     = length(aws_kms_alias.identity_mfa) == 0
    error_message = "No key means no alias: an alias with no target is not a valid resource."
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_mfa) == 0
    error_message = "With no key there must be no MFA grant: a policy naming a key that does not exist is invalid rather than merely useless."
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_DATA_KEY_ARN")
    error_message = "With no key, IDENTITY_DATA_KEY_ARN must be absent rather than empty: the function's environment should name only the keys that exist."
  }

  assert {
    condition     = length(aws_kms_key.identity_signing) == 1 && length(aws_iam_role_policy.identity_signing) == 1
    error_message = "Turning the envelope key off must leave the signing key and its grant alone."
  }
}

run "a_supplied_key_is_granted_and_exported_the_same_way_a_created_one_is" {
  command = plan

  variables {
    enable_mfa_encryption_key = false
    mfa_encryption_key_arn    = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    identity_role_name        = "example-staging-identity"
    attach_role_policies      = true
    identity_role_arn         = "arn:aws:iam::123456789012:role/example-staging-identity"
  }

  assert {
    condition     = length(aws_kms_key.identity_mfa) == 0
    error_message = "A supplied key must not also be created: that is the point of supplying one."
  }

  assert {
    condition     = local.mfa_key_arn == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "The supplied ARN must be the key the module treats as the envelope key."
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_mfa) == 1
    error_message = "A supplied key must still be granted to the identity role: the function cannot seal a seed it may not call GenerateDataKey on."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_DATA_KEY_ARN"] == var.mfa_encryption_key_arn
    error_message = "IDENTITY_DATA_KEY_ARN must carry the supplied ARN, so the package seals under the key the grant names."
  }

  assert {
    condition     = strcontains(local.mfa_policy_json, var.mfa_encryption_key_arn)
    error_message = "The grant must name the supplied key ARN as its resource rather than a wildcard."
  }
}

run "an_alias_arn_is_rejected_as_a_supplied_key" {
  command = plan

  variables {
    enable_mfa_encryption_key = false
    mfa_encryption_key_arn    = "not-an-arn"
  }

  expect_failures = [var.mfa_encryption_key_arn]
}

run "the_context_condition_can_be_dropped_for_a_package_that_sends_a_different_one" {
  command = plan

  variables {
    mfa_encryption_context_purpose = null
    identity_role_name             = "example-staging-identity"
    attach_role_policies           = true
    identity_role_arn              = "arn:aws:iam::123456789012:role/example-staging-identity"
  }

  assert {
    condition     = !contains(keys(local.mfa_policy_statement), "Condition")
    error_message = "A null purpose must omit the condition entirely rather than pinning an empty string, which no request would match."
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_mfa) == 1
    error_message = "Dropping the condition must not drop the grant."
  }
}

run "a_custom_purpose_reaches_both_halves_of_the_pair" {
  command = plan

  variables {
    mfa_encryption_context_purpose = "totp-v2"
    identity_role_name             = "example-staging-identity"
    attach_role_policies           = true
    identity_role_arn              = "arn:aws:iam::123456789012:role/example-staging-identity"
  }

  assert {
    condition     = local.mfa_policy_statement.Condition.StringEquals["kms:EncryptionContext:purpose"] == "totp-v2"
    error_message = "The role policy must pin whatever purpose the consumer set, since a condition naming a different value than the package sends denies every call."
  }
}
