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

run "versioning_is_enabled_by_default" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Enabled"
    error_message = "Versioning must default to Enabled. It is what lets a bad Lambda deploy be rolled back to the previous package, and it is also the only thing the noncurrent-version expiry rule below has to act on."
  }

  assert {
    condition     = length([aws_s3_bucket_versioning.this]) == 1
    error_message = "Versioning must always be managed explicitly rather than left to whatever the bucket happened to have. An unversioned artifacts bucket overwrites the previous package in place with no way back."
  }
}

run "versioning_can_be_suspended_when_a_consumer_asks_for_it" {
  command = plan

  variables {
    versioning_status = "Suspended"
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Suspended"
    error_message = "Suspended must be a real passthrough so an existing bucket that was never versioned can be adopted without the module flipping a setting the consumer did not ask for."
  }
}

run "an_unknown_versioning_status_is_rejected" {
  command = plan

  variables {
    versioning_status = "Disabled"
  }

  expect_failures = [var.versioning_status]
}

run "the_lifecycle_rule_expires_noncurrent_versions_and_aborts_stalled_uploads" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this.rule) == 1
    error_message = "There must be exactly one lifecycle rule. S3 evaluates every rule against every object, so a second rule quietly introduced here would apply to artifacts nobody expected it to touch."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule).status == "Enabled"
    error_message = "The rule must be Enabled. A Disabled rule leaves every noncurrent package in the bucket forever, and the storage bill grows with every deploy with nothing to show for it."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this.rule).noncurrent_version_expiration).noncurrent_days == 30
    error_message = "Noncurrent versions must default to a 30 day retention, which is long enough to roll a release back and short enough that the bucket does not accumulate every package ever deployed."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this.rule).abort_incomplete_multipart_upload).days_after_initiation == 7
    error_message = "Stalled multipart uploads must be aborted after 7 days. Their parts are billed as storage but are invisible in the object listing, so without this rule a failed deploy leaks cost nobody can see."
  }
}

run "the_rule_carries_an_empty_filter_so_it_covers_every_artifact" {
  command = plan

  assert {
    condition     = length(one(aws_s3_bucket_lifecycle_configuration.this.rule).filter) == 1
    error_message = "The rule must carry an explicit empty filter block. S3 requires a rule to declare either a filter or a prefix, and a rule without one is rejected at apply time."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this.rule).filter).prefix == ""
    error_message = "The filter must carry no prefix, so the rule applies to every object in the bucket. A prefix here would silently exempt any artifact uploaded under a different key from expiry."
  }
}

run "the_rule_id_defaults_to_the_documented_name_and_is_overridable" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule).id == "expire-noncurrent-artifacts"
    error_message = "The rule id must default to expire-noncurrent-artifacts. The id is what identifies the rule in place, so a changed default rewrites the rule on every estate that never set the variable."
  }
}

run "an_adopted_bucket_can_keep_the_rule_id_it_already_has" {
  command = plan

  variables {
    lifecycle_rule_id                      = "expire-noncurrent"
    noncurrent_version_expiration_days     = 14
    abort_incomplete_multipart_upload_days = 3
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule).id == "expire-noncurrent"
    error_message = "The rule id must be a passthrough. The Portfolio estate already holds a rule called expire-noncurrent, and forcing the module default on it would rewrite a rule that is working."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this.rule).noncurrent_version_expiration).noncurrent_days == 14
    error_message = "A shorter retention must reach the rule, so a busy estate that deploys many times a day can trade rollback depth for storage cost."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this.rule).abort_incomplete_multipart_upload).days_after_initiation == 3
    error_message = "The abort window must be a passthrough too. It is separate from the retention window because a stalled upload is waste from the moment it stalls, not a version worth keeping."
  }
}

run "an_empty_lifecycle_rule_id_is_rejected" {
  command = plan

  variables {
    lifecycle_rule_id = ""
  }

  expect_failures = [var.lifecycle_rule_id]
}

run "a_zero_noncurrent_expiration_is_rejected" {
  command = plan

  variables {
    noncurrent_version_expiration_days = 0
  }

  expect_failures = [var.noncurrent_version_expiration_days]
}

run "a_fractional_noncurrent_expiration_is_rejected" {
  command = plan

  variables {
    noncurrent_version_expiration_days = 1.5
  }

  expect_failures = [var.noncurrent_version_expiration_days]
}

run "a_zero_abort_window_is_rejected" {
  command = plan

  variables {
    abort_incomplete_multipart_upload_days = 0
  }

  expect_failures = [var.abort_incomplete_multipart_upload_days]
}

run "a_fractional_abort_window_is_rejected" {
  command = plan

  variables {
    abort_incomplete_multipart_upload_days = 7.5
  }

  expect_failures = [var.abort_incomplete_multipart_upload_days]
}
