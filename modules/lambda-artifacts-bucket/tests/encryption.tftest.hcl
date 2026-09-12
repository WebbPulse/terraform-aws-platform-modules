variables {
  bucket = "example-staging-lambda-artifacts"
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

run "the_encryption_resource_is_off_by_default_for_clean_adoption" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_server_side_encryption_configuration.this) == 0
    error_message = "enable_sse must default to false. S3 has encrypted every new object with AES256 since January 2023 whether or not the bucket carries this resource, so the default exists to let a bucket that never had one be adopted without adding a resource to its plan."
  }
}

run "enabling_sse_writes_an_explicit_aes256_rule" {
  command = plan

  variables {
    enable_sse = true
  }

  assert {
    condition     = length(aws_s3_bucket_server_side_encryption_configuration.this) == 1
    error_message = "enable_sse true must create exactly one encryption configuration, so the bucket shows its own rule in the console rather than relying on the account default nobody can see from here."
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_server_side_encryption_configuration.this[*].rule)).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The algorithm must default to AES256, which is SSE-S3 and costs nothing per request. Both estates rely on this default, so a change here would bill every artifact read against KMS."
  }

  assert {
    condition     = var.sse_kms_master_key_id == null
    error_message = "sse_kms_master_key_id must default to null so an AES256 rule leaves it unset. A key id on an AES256 rule is meaningless and would either be silently ignored or make the rule diff on every plan."
  }
}

run "a_kms_rule_carries_the_key_and_a_bucket_key" {
  command = plan

  variables {
    enable_sse             = true
    sse_algorithm          = "aws:kms"
    sse_kms_master_key_id  = "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
    sse_bucket_key_enabled = true
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_server_side_encryption_configuration.this[*].rule)).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "An estate that needs a customer managed key must be able to select aws:kms, because SSE-S3 gives no way to revoke access to existing artifacts by disabling a key."
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_server_side_encryption_configuration.this[*].rule)).apply_server_side_encryption_by_default).kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
    error_message = "The key id must reach the rule. A KMS algorithm with no key silently falls back to the AWS managed aws/s3 key, which is a different key with a different policy than the one the consumer named."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this[*].rule)).bucket_key_enabled
    error_message = "S3 Bucket Keys must be a real passthrough. On a KMS encrypted bucket they cut the per request KMS charge by orders of magnitude, and a Lambda cold start reads the package on every scale out."
  }
}

run "the_bucket_key_setting_is_left_unset_by_default" {
  command = plan

  variables {
    enable_sse = true
  }

  assert {
    condition     = var.sse_bucket_key_enabled == null
    error_message = "sse_bucket_key_enabled must default to null so the attribute is left unset on the rule. A rule written without it stores false, and defaulting to true here would show as a diff on every adopted bucket that never enabled one."
  }
}

run "a_dsse_kms_rule_is_accepted" {
  command = plan

  variables {
    enable_sse            = true
    sse_algorithm         = "aws:kms:dsse"
    sse_kms_master_key_id = "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_server_side_encryption_configuration.this[*].rule)).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms:dsse"
    error_message = "Dual layer server side encryption must be selectable for an estate under a compliance regime that requires it, since the only alternative would be managing the encryption resource outside the module."
  }
}

run "an_unknown_sse_algorithm_is_rejected" {
  command = plan

  variables {
    enable_sse    = true
    sse_algorithm = "AES128"
  }

  expect_failures = [var.sse_algorithm]
}

run "an_sse_algorithm_is_validated_even_when_sse_is_off" {
  command = plan

  variables {
    enable_sse    = false
    sse_algorithm = "none"
  }

  expect_failures = [var.sse_algorithm]
}
