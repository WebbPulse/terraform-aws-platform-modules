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

run "one_key_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.identity_signing) == 1
    error_message = "The default must be a single signing key: one is the steady state and a second is a rotation in progress."
  }

  assert {
    condition     = aws_kms_key.identity_signing[0].customer_master_key_spec == "RSA_2048"
    error_message = "The HTTP API JWT authorizer verifies RSA signatures only, so the key spec must be an RSA one."
  }

  assert {
    condition     = aws_kms_key.identity_signing[0].key_usage == "SIGN_VERIFY"
    error_message = "A signing key must be SIGN_VERIFY; an ENCRYPT_DECRYPT key cannot sign a token."
  }

  assert {
    condition     = !aws_kms_key.identity_signing[0].enable_key_rotation
    error_message = "Automatic key rotation must stay off: rotation in this design is by adding a key, never by mutating one."
  }

  assert {
    condition     = aws_kms_key.identity_signing[0].deletion_window_in_days == 30
    error_message = "The deletion window must default to the 30 day maximum: dropping a key an already issued token still references is the one mistake here with no recovery."
  }

  assert {
    condition     = aws_kms_alias.identity_signing[0].name == "alias/example-staging-identity-signing"
    error_message = "The alias name is a pure function of name_prefix, and a consumer passes it where KMS accepts a key id."
  }
}

run "rotation_step_one_adds_a_key_without_promoting_it" {
  command = plan

  variables {
    signing_key_count = 2
  }

  assert {
    condition     = length(aws_kms_key.identity_signing) == 2
    error_message = "signing_key_count must create that many keys."
  }

  assert {
    condition     = length(local.signing_key_order) == 2 && local.signing_key_order[0] == 0
    error_message = "With active_signing_key still 0, the original key must stay at the head of the list and keep signing."
  }

  assert {
    condition     = local.signing_key_order[1] == 1
    error_message = "The newly added key must be published in the JWKS, which means being in the list, without signing."
  }

  assert {
    condition     = var.active_signing_key == 0
    error_message = "The alias must point at the active signer, which is still key 0 at this step."
  }
}

run "rotation_step_two_promotes_the_new_key" {
  command = plan

  variables {
    signing_key_count  = 2
    active_signing_key = 1
  }

  assert {
    condition     = local.signing_key_order[0] == 1
    error_message = "The promoted key must be first: webbpulse.identity signs with signing_key_arns[0]."
  }

  assert {
    condition     = local.signing_key_order[1] == 0
    error_message = "The retired key must stay in the list so the JWKS still serves it and tokens it signed still verify."
  }

  assert {
    condition     = local.signing_key_order[0] == var.active_signing_key
    error_message = "The alias must follow the active signer to the promoted key, and the head of the list is the same index it targets."
  }
}

run "the_active_key_leads_and_the_rest_keep_index_order" {
  command = plan

  variables {
    signing_key_count  = 4
    active_signing_key = 2
  }

  assert {
    condition     = length(local.signing_key_order) == 4
    error_message = "Every key must be published in the JWKS, so every one must appear in the list exactly once."
  }

  assert {
    condition     = local.signing_key_order[0] == 2
    error_message = "The active key must lead the list whatever its index."
  }

  assert {
    condition     = local.signing_key_order[1] == 0 && local.signing_key_order[2] == 1 && local.signing_key_order[3] == 3
    error_message = "The remaining keys must follow in index order, so the list is a deterministic function of the two inputs."
  }

  assert {
    condition     = length(distinct(local.signing_key_order)) == 4
    error_message = "A duplicate entry would serve the same kid twice in the JWKS, which some verifiers reject."
  }
}

run "more_than_four_keys_is_rejected" {
  command = plan

  variables {
    signing_key_count = 5
  }

  expect_failures = [var.signing_key_count]
}

run "active_key_must_index_a_key_that_exists" {
  command = plan

  variables {
    signing_key_count  = 1
    active_signing_key = 1
  }

  expect_failures = [var.active_signing_key]
}

run "a_non_rsa_key_spec_is_rejected" {
  command = plan

  variables {
    signing_key_spec = "ECC_NIST_P256"
  }

  expect_failures = [var.signing_key_spec]
}

run "a_trailing_slash_on_the_issuer_is_rejected" {
  command = plan

  variables {
    issuer = "https://api.staging.example.com/api/auth/"
  }

  expect_failures = [var.issuer]
}

run "a_plaintext_issuer_is_rejected" {
  command = plan

  variables {
    issuer = "http://api.staging.example.com/api/auth"
  }

  expect_failures = [var.issuer]
}

run "the_key_reproduces_an_adopted_keys_tags" {
  command = plan

  variables {
    name_tag = true
    tags = {
      Component = "identity"
      Milestone = "M1"
    }
  }

  assert {
    condition     = aws_kms_key.identity_signing[0].tags["Name"] == "example-staging-identity-signing"
    error_message = "name_tag must put Name = <name_prefix>-identity-signing on the key, matching a hand-written key in an estate that tags by Name."
  }

  assert {
    condition     = aws_kms_key.identity_signing[0].tags["Component"] == "identity" && aws_kms_key.identity_signing[0].tags["Milestone"] == "M1"
    error_message = "var.tags must reach the signing key, so an adopting consumer keeps the tags the key already has."
  }
}

run "no_tags_means_no_tags_argument" {
  command = plan

  assert {
    condition     = aws_kms_key.identity_signing[0].tags == null
    error_message = "With no tags and no name_tag the key must pass null rather than an empty map, so it plans identically to a resource that never set tags."
  }
}
