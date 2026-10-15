variables {
  name_prefix = "example-staging"
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

run "a_name_prefix_with_a_space_is_rejected" {
  command = plan

  variables {
    name_prefix = "example staging"
  }

  expect_failures = [var.name_prefix]
}

run "a_sampling_percentage_above_one_hundred_is_rejected" {
  command = plan

  variables {
    indexing_rule_sampling_percentage = 101
  }

  expect_failures = [var.indexing_rule_sampling_percentage]
}

run "a_negative_sampling_percentage_is_rejected" {
  command = plan

  variables {
    indexing_rule_sampling_percentage = -1
  }

  expect_failures = [var.indexing_rule_sampling_percentage]
}

run "an_unsupported_application_signals_retention_is_rejected" {
  command = plan

  variables {
    application_signals_log_group_retention_in_days = 31
  }

  expect_failures = [var.application_signals_log_group_retention_in_days]
}

run "adopting_application_signals_without_a_name_is_rejected" {
  command = plan

  variables {
    adopt_application_signals_log_group = true
    application_signals_log_group_name  = null
  }

  expect_failures = [var.adopt_application_signals_log_group]
}

run "a_span_sample_ratio_above_one_is_rejected" {
  command = plan

  variables {
    span_sample_ratio = 1.5
  }

  expect_failures = [var.span_sample_ratio]
}

run "a_null_span_sample_ratio_publishes_no_environment" {
  command = plan

  assert {
    condition     = length(output.otel_environment_variables) == 0
    error_message = "A null span_sample_ratio must publish an empty map."
  }

  assert {
    condition     = output.application_signals_log_group_arn == null
    error_message = "The Application Signals group must not be adopted by default."
  }
}

run "a_span_sample_ratio_publishes_the_sdk_variable" {
  command = plan

  variables {
    span_sample_ratio = 0.1
  }

  assert {
    condition     = output.otel_environment_variables["WEBBPULSE_OTEL_SAMPLE_RATIO"] == "0.1"
    error_message = "span_sample_ratio must publish WEBBPULSE_OTEL_SAMPLE_RATIO."
  }
}
