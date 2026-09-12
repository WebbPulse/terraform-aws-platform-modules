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

run "all_four_public_access_flags_are_on_by_default" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_acls
    error_message = "block_public_acls must be true. Without it an object can be uploaded with a public-read ACL, and a deploy pipeline that sets one would publish every Lambda package in the account's backend to the internet."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_policy
    error_message = "block_public_policy must be true. Without it a bucket policy granting Principal \"*\" can be attached, which is the single change that turns this bucket from private to world readable."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.this.ignore_public_acls
    error_message = "ignore_public_acls must be true. Blocking new public ACLs is not enough on a bucket that may already hold objects carrying one, and ignoring them is what neutralises those."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.this.restrict_public_buckets
    error_message = "restrict_public_buckets must be true. It is the flag that stops a bucket policy granting access to any AWS principal at all, which is the widest of the four exposures."
  }
}

run "the_public_access_block_is_not_configurable_and_stays_on_in_every_shape" {
  command = plan

  variables {
    force_destroy             = true
    versioning_status         = "Suspended"
    enable_sse                = true
    create_placeholder_object = false
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "No combination of this module's inputs may weaken the public access block. The module exposes no variable for it precisely so that a bucket holding deployable code can never be made readable by anyone outside the account."
  }

  assert {
    condition     = length([aws_s3_bucket_public_access_block.this]) == 1
    error_message = "Exactly one public access block must always be created. Making it conditional on any toggle would let a consumer create the bucket without it and leave the account's block settings as the only protection."
  }
}

run "the_bucket_is_created_with_the_name_the_consumer_gave" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.bucket == "example-staging-lambda-artifacts"
    error_message = "The bucket name must be var.bucket verbatim. Bucket names are globally unique and cannot be renamed, so any decoration added here would replace the bucket and orphan every artifact in it."
  }

  assert {
    condition     = !aws_s3_bucket.this.force_destroy
    error_message = "force_destroy must default to false. The bucket is versioned, so a true default would let a terraform destroy silently delete every historical Lambda package with no confirmation step."
  }
}

run "force_destroy_can_be_turned_on_deliberately" {
  command = plan

  variables {
    force_destroy = true
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy
    error_message = "force_destroy must be a real passthrough, so a throwaway staging estate can be torn down without a manual object sweep first. It is safe only because the default is false."
  }
}

run "tags_reach_the_bucket_as_given" {
  command = plan

  variables {
    tags = {
      Project     = "example"
      Environment = "staging"
    }
  }

  assert {
    condition     = aws_s3_bucket.this.tags == tomap({ Project = "example", Environment = "staging" })
    error_message = "Tags must reach the bucket unchanged. The app-baseline resource group selects members by tag, so a dropped or rewritten tag removes the artifacts bucket from the estate's own inventory."
  }
}

run "a_bucket_name_with_an_uppercase_letter_is_rejected" {
  command = plan

  variables {
    bucket = "Example-Staging-Lambda-Artifacts"
  }

  expect_failures = [var.bucket]
}

run "a_bucket_name_with_an_underscore_is_rejected" {
  command = plan

  variables {
    bucket = "example_staging_artifacts"
  }

  expect_failures = [var.bucket]
}

run "a_bucket_name_shorter_than_three_characters_is_rejected" {
  command = plan

  variables {
    bucket = "ab"
  }

  expect_failures = [var.bucket]
}

run "a_bucket_name_ending_in_a_hyphen_is_rejected" {
  command = plan

  variables {
    bucket = "example-staging-artifacts-"
  }

  expect_failures = [var.bucket]
}
