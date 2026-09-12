variables {
  name = "example-staging-frontend"
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

run "name_alone_supplies_the_bucket_and_the_origin_access_control_name" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.bucket == "example-staging-frontend"
    error_message = "A consumer that passes only name must get a bucket called exactly name: that is the contract the deploy pipeline syncs into, and any other spelling silently publishes to a bucket nothing serves."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.this.name == "example-staging-frontend"
    error_message = "The origin access control must also default to name, so a greenfield consumer names one thing and gets a consistent estate."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.this.origin_access_control_origin_type == "s3"
    error_message = "The bucket origin must be signed by an s3 type origin access control: the lambda type signs a different payload and CloudFront would get 403 from S3 on every object."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.this.signing_behavior == "always"
    error_message = "Signing must be always rather than no-override, because the bucket policy admits only requests that arrive with a CloudFront SourceArn and an unsigned request is simply denied."
  }
}

run "bucket_name_and_origin_access_control_name_override_name_independently" {
  command = plan

  variables {
    bucket_name                = "legacy-example-site-bucket"
    origin_access_control_name = "example-staging-frontend-oac"
    origin_id                  = "example-staging-frontend-s3"
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "legacy-example-site-bucket"
    error_message = "bucket_name must win over name: adoption of an existing estate depends on reproducing a bucket name that was chosen before this module existed, and a mismatch destroys and recreates the site content."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.this.name == "example-staging-frontend-oac"
    error_message = "origin_access_control_name must override name on its own, because CarModPicker adopts an access control whose name carries an -oac suffix the bucket name does not have."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.origin).origin_id == "example-staging-frontend-s3"
    error_message = "origin_id must reach the distribution origin verbatim: every behavior references it by name, so an origin_id that does not match the adopted distribution replaces every behavior."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].target_origin_id == "example-staging-frontend-s3"
    error_message = "The default behavior must target the configured origin_id rather than a hardcoded one, otherwise the distribution plans with a behavior pointing at an origin that does not exist."
  }
}

run "the_bucket_is_private_and_readable_only_by_this_distribution" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_policy && aws_s3_bucket_public_access_block.this.block_public_acls && aws_s3_bucket_public_access_block.this.ignore_public_acls && aws_s3_bucket_public_access_block.this.restrict_public_buckets
    error_message = "All four public access block switches must be on: the site is served only through CloudFront, and a bucket that can be made public by a later policy edit is a way to bypass the distribution entirely, including the access gate."
  }

  assert {
    condition     = var.bucket_policy_sid == "AllowCloudFrontServicePrincipal"
    error_message = "bucket_policy_sid must default to AllowCloudFrontServicePrincipal, which is the Sid the AWS console writes, so an adopter who never set the input plans a no-op on the live policy."
  }
}

run "tags_reach_the_bucket_and_distribution_tags_only_the_distribution" {
  command = plan

  variables {
    tags              = { Environment = "staging" }
    distribution_tags = { Name = "example-staging-frontend" }
  }

  assert {
    condition     = aws_s3_bucket.this.tags["Environment"] == "staging"
    error_message = "tags must reach the bucket: it is the shared tag set both resources carry."
  }

  assert {
    condition     = !contains(keys(aws_s3_bucket.this.tags), "Name")
    error_message = "distribution_tags must not reach the bucket. It exists precisely because an adopted distribution carries a Name tag the bucket does not, and leaking it would put a permanent diff on the bucket."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.tags["Environment"] == "staging" && aws_cloudfront_distribution.this.tags["Name"] == "example-staging-frontend"
    error_message = "The distribution must carry tags merged with distribution_tags on top, so the shared set and the distribution only set both land."
  }
}

run "a_name_that_is_not_a_valid_bucket_name_is_rejected" {
  command = plan

  variables {
    name = "Example_Staging_Frontend"
  }

  expect_failures = [var.name]
}

run "a_bucket_name_with_uppercase_is_rejected" {
  command = plan

  variables {
    bucket_name = "Example-Staging-Frontend"
  }

  expect_failures = [var.bucket_name]
}

run "a_bucket_policy_sid_with_punctuation_is_rejected" {
  command = plan

  variables {
    bucket_policy_sid = "Allow-CloudFront-OAC"
  }

  expect_failures = [var.bucket_policy_sid]
}

run "an_empty_origin_id_is_rejected" {
  command = plan

  variables {
    origin_id = ""
  }

  expect_failures = [var.origin_id]
}
