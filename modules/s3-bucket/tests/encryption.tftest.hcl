variables {
  bucket = "example-staging-state"
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

run "the_bucket_is_encrypted_with_sse_s3_when_no_key_is_given" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "With no key the rule must be AES256, which is SSE-S3 and costs nothing per request. A Terraform run reads and writes state on every plan, so defaulting to KMS would bill every one of those requests."
  }

  assert {
    condition     = local.key_arn == null
    error_message = "An AES256 rule must leave the key id unset. A key id on an AES256 rule is meaningless and makes the rule diff on every plan."
  }

  assert {
    condition     = local.uses_kms == false
    error_message = "Bucket Keys must be left unset without a KMS key, because the setting only affects KMS requests and writing it on an SSE-S3 bucket is a diff with no effect. The module derives that from uses_kms, so this is the value the rule reads."
  }
}

run "a_caller_supplied_key_is_used_without_creating_one" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "A caller supplied key must not create a second key. Two keys on one bucket means objects written under the wrong one become unreadable when the unused key is deleted."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "A supplied key must switch the rule to aws:kms. Leaving it on AES256 would silently ignore the key the caller named and encrypt with SSE-S3 instead."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
    error_message = "The supplied key ARN must reach the rule. A KMS algorithm with no key falls back to the AWS managed aws/s3 key, which has a different policy than the key the caller chose."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled == true
    error_message = "Bucket Keys must default to on with a KMS key. They cut the per request KMS charge by orders of magnitude, and state is read on every plan."
  }
}

run "the_module_creates_a_rotating_customer_managed_key_when_asked" {
  command = plan

  variables {
    create_kms_key = true
  }

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "create_kms_key must create exactly one key, so an estate that needs to revoke access to everything in the bucket at once has a key it can disable."
  }

  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation
    error_message = "Rotation must default to on. AWS keeps every previous backing key so old objects still decrypt, which makes rotation free of operational risk and there is no reason to leave it off."
  }

  assert {
    condition     = aws_kms_key.this[0].deletion_window_in_days == 30
    error_message = "The deletion window must default to the 30 day maximum. Nothing in the bucket can be read once the key is destroyed, so the longest possible window to notice a mistaken deletion is the right default on a bucket holding state."
  }

  assert {
    condition     = length(aws_kms_alias.this) == 1 && aws_kms_alias.this[0].name == "alias/example-staging-state"
    error_message = "An alias must be created and named after the bucket, because a bare key id in the console tells an operator nothing about what the key protects."
  }
}

run "the_generated_key_policy_grants_the_account_root_and_named_principals" {
  command = plan

  variables {
    create_kms_key               = true
    kms_key_extra_principal_arns = ["arn:aws:iam::123456789012:role/example-runner"]
  }

  assert {
    condition     = length([for s in jsondecode(data.aws_iam_policy_document.key[0].json).Statement : s if s.Sid == "EnableIAMPoliciesInThisAccount"]) == 1
    error_message = "The key policy must grant the account root kms:* . Without it the key is unmanageable: IAM policies in the account have no effect on a KMS key unless the key policy delegates to them, and the key cannot be fixed afterwards."
  }

  assert {
    condition     = length([for s in jsondecode(data.aws_iam_policy_document.key[0].json).Statement : s if s.Sid == "AllowNamedPrincipalsToUseTheKey"]) == 1
    error_message = "Named extra principals must get their own statement, which is what a role in another account needs, since a cross-account grant cannot be expressed through the account root delegation."
  }
}

run "the_key_policy_holds_only_the_root_statement_when_no_principals_are_named" {
  command = plan

  variables {
    create_kms_key = true
  }

  assert {
    condition     = length(jsondecode(data.aws_iam_policy_document.key[0].json).Statement) == 1
    error_message = "With no extra principals the policy must carry exactly the root statement. An empty principals list in a KMS statement is rejected by the API, so the statement has to be omitted rather than written empty."
  }
}

run "an_alias_can_be_suppressed_and_a_bare_name_is_prefixed" {
  command = plan

  variables {
    create_kms_key = true
    kms_key_alias  = "example-state"
  }

  assert {
    condition     = aws_kms_alias.this[0].name == "alias/example-state"
    error_message = "A bare alias name must get the alias/ prefix added. KMS rejects an alias without it, and making the caller remember the prefix is the kind of detail a shared module should absorb."
  }
}

run "an_alias_already_carrying_the_prefix_is_not_doubled" {
  command = plan

  variables {
    create_kms_key = true
    kms_key_alias  = "alias/example-state"
  }

  assert {
    condition     = aws_kms_alias.this[0].name == "alias/example-state"
    error_message = "An alias that already carries the prefix must be used as given, not turned into alias/alias/example-state."
  }
}

run "a_too_short_key_deletion_window_is_rejected" {
  command = plan

  variables {
    create_kms_key                  = true
    kms_key_deletion_window_in_days = 3
  }

  expect_failures = [var.kms_key_deletion_window_in_days]
}
