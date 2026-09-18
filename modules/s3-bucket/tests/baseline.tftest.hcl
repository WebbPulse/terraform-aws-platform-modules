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

run "the_bucket_blocks_every_route_to_public_access" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "All four public access block settings must be on and not configurable. This bucket holds Terraform state, which carries every resource id and every value a provider marked sensitive, so there is no case for a public read."
  }
}

run "ownership_is_bucket_owner_enforced_so_acls_are_off" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.this.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "Ownership must default to BucketOwnerEnforced, which turns ACLs off entirely. With ACLs live an object written by another account stays owned by that account and the bucket owner cannot read it, which is the classic cross-account state bucket failure."
  }
}

run "versioning_is_enabled_by_default" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Enabled"
    error_message = "Versioning must default to Enabled. A state file overwritten by a bad apply is only recoverable from a previous version, and an unversioned state bucket has no way back at all."
  }
}

run "versioning_can_be_suspended_for_an_adopted_bucket" {
  command = plan

  variables {
    versioning_status = "Suspended"
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Suspended"
    error_message = "Suspended must be a real passthrough so a bucket that was never versioned can be adopted without the module flipping a setting on the first apply."
  }
}

run "force_destroy_is_off_by_default" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy must default to false. The bucket is versioned, so a true default would let a destroy take the state history with it without anyone having asked for that."
  }
}

run "no_lifecycle_cors_or_notification_resource_exists_by_default" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this) == 0
    error_message = "No lifecycle configuration may be written by default. An expiry rule on a bucket holding Terraform state would delete state, and this module is general purpose, so it cannot guess a safe rule."
  }

  assert {
    condition     = length(aws_s3_bucket_cors_configuration.this) == 0 && length(aws_s3_bucket_notification.eventbridge) == 0
    error_message = "CORS and EventBridge notifications must both be off by default, so a bucket nobody fetches cross-origin carries no CORS rule and a bucket nothing watches raises no events."
  }
}

run "an_invalid_bucket_name_is_rejected" {
  command = plan

  variables {
    bucket = "Example_Staging_State"
  }

  expect_failures = [var.bucket]
}

run "an_unknown_ownership_setting_is_rejected" {
  command = plan

  variables {
    object_ownership = "BucketOwnerFull"
  }

  expect_failures = [var.object_ownership]
}
