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

run "a_rule_becomes_one_lifecycle_rule_keyed_by_its_id" {
  command = plan

  variables {
    lifecycle_rules = {
      expire-noncurrent = {
        noncurrent_version_expiration_days     = 90
        abort_incomplete_multipart_upload_days = 7
      }
    }
  }

  assert {
    condition     = length(one(aws_s3_bucket_lifecycle_configuration.this).rule) == 1
    error_message = "One map entry must produce exactly one rule, keyed by the map key. S3 evaluates every rule against every object, so a rule appearing twice would apply an expiry nobody asked for."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this).rule).id == "expire-noncurrent"
    error_message = "The rule id must be the map key. The id is what identifies a rule in place, so deriving it from anything else would rewrite the rule whenever that other thing changed."
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).noncurrent_version_expiration).noncurrent_days == 90
    error_message = "The noncurrent expiry must reach the rule. On a state bucket it is the only thing keeping old state versions from accumulating forever, and it is the setting most likely to be typed into the wrong field."
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).abort_incomplete_multipart_upload).days_after_initiation == 7
    error_message = "The abort window must reach the rule. Stalled multipart parts are billed as storage but invisible in an object listing, so without it a failed upload leaks cost nobody can see."
  }
}

run "a_rule_with_no_prefix_or_tags_carries_an_empty_filter" {
  command = plan

  variables {
    lifecycle_rules = {
      expire-noncurrent = {
        noncurrent_version_expiration_days = 90
      }
    }
  }

  assert {
    condition     = length(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).filter) == 1
    error_message = "A rule must carry an explicit filter block. S3 rejects a rule that declares neither a filter nor a prefix, and the rejection arrives at apply time rather than in the plan."
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).filter).prefix == ""
    error_message = "A rule given no prefix must filter on nothing, so it covers every object. A stray prefix would silently exempt whatever was stored under a different key."
  }
}

run "a_prefix_scopes_the_rule" {
  command = plan

  variables {
    lifecycle_rules = {
      expire-tarballs = {
        prefix          = "config/"
        expiration_days = 30
      }
    }
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).filter).prefix == "config/"
    error_message = "A prefix must scope the rule, which is what lets one bucket hold state that is never expired alongside config tarballs that are."
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).expiration).days == 30
    error_message = "A current-version expiry must be expressible for a prefix holding disposable objects, because a tarball uploaded per run is waste a week later."
  }
}

run "a_rule_can_be_disabled_without_being_removed" {
  command = plan

  variables {
    lifecycle_rules = {
      expire-noncurrent = {
        enabled                            = false
        noncurrent_version_expiration_days = 90
      }
    }
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this).rule).status == "Disabled"
    error_message = "A rule must be disablable in place. Deleting the entry to stop a rule loses the settings, while Disabled keeps them visible so the rule can be turned back on with the same numbers."
  }
}

run "transitions_reach_the_rule" {
  command = plan

  variables {
    lifecycle_rules = {
      archive-old = {
        transitions = [{
          days          = 30
          storage_class = "STANDARD_IA"
        }]
        noncurrent_version_transitions = [{
          days          = 30
          storage_class = "GLACIER_IR"
        }]
      }
    }
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).transition).storage_class == "STANDARD_IA"
    error_message = "A current-version transition must reach the rule, so a bucket holding a registry nobody reads often can be moved to a cheaper class without expiring anything."
  }

  assert {
    condition     = one(one(one(aws_s3_bucket_lifecycle_configuration.this).rule).noncurrent_version_transition).storage_class == "GLACIER_IR"
    error_message = "A noncurrent-version transition must reach the rule under its own noncurrent_days field. The two transition blocks take differently named day arguments, which is exactly the kind of mapping a module should get right once."
  }
}

run "a_rule_that_does_nothing_is_rejected" {
  command = plan

  variables {
    lifecycle_rules = {
      pointless = {
        prefix = "config/"
      }
    }
  }

  expect_failures = [var.lifecycle_rules]
}

run "an_unknown_storage_class_is_rejected" {
  command = plan

  variables {
    lifecycle_rules = {
      archive-old = {
        transitions = [{
          days          = 30
          storage_class = "GLACIER_FLEX"
        }]
      }
    }
  }

  expect_failures = [var.lifecycle_rules]
}

run "a_fractional_retention_is_rejected" {
  command = plan

  variables {
    lifecycle_rules = {
      expire-noncurrent = {
        noncurrent_version_expiration_days = 1.5
      }
    }
  }

  expect_failures = [var.lifecycle_rules]
}

run "eventbridge_notifications_can_be_turned_on" {
  command = plan

  variables {
    enable_eventbridge_notifications = true
  }

  assert {
    condition     = one(aws_s3_bucket_notification.eventbridge).eventbridge
    error_message = "The EventBridge toggle must set eventbridge on the notification. It is the one notification shape that does not need a per-target configuration, so two consumers watching the same bucket cannot clobber each other's wiring."
  }
}

run "cors_rules_are_written_in_order" {
  command = plan

  variables {
    cors_rules = [{
      allowed_methods = ["GET", "HEAD"]
      allowed_origins = ["https://example.com"]
      max_age_seconds = 3600
    }]
  }

  assert {
    condition     = contains(one(one(aws_s3_bucket_cors_configuration.this).cors_rule).allowed_origins, "https://example.com")
    error_message = "A CORS rule's origins must be a passthrough, because a browser compares the Origin header against them exactly and a rewritten value fails the preflight with no useful error."
  }

  assert {
    condition     = one(one(aws_s3_bucket_cors_configuration.this).cors_rule).max_age_seconds == 3600
    error_message = "The preflight cache age must reach the rule, so a browser is not made to re-preflight every request."
  }
}

run "a_cors_rule_with_no_origin_is_rejected" {
  command = plan

  variables {
    cors_rules = [{
      allowed_methods = ["GET"]
      allowed_origins = []
    }]
  }

  expect_failures = [var.cors_rules]
}

run "an_unknown_cors_method_is_rejected" {
  command = plan

  variables {
    cors_rules = [{
      allowed_methods = ["PATCH"]
      allowed_origins = ["https://example.com"]
    }]
  }

  expect_failures = [var.cors_rules]
}
