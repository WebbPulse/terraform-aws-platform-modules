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

run "null_overrides_keep_the_known_id_behaviour" {
  command = plan

  variables {
    http_api_id                       = "abc123"
    lambda_function_name              = "example-staging-api"
    lambda_errors_alarm_function_name = "example-staging-worker"
    alarms = {
      api_integration_latency  = true
      lambda_account_errors    = false
      lambda_account_throttles = false
    }
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.api_5xx) == 1 && length(aws_cloudwatch_metric_alarm.api_integration_latency) == 1
    error_message = "A known http_api_id with a null override must still create the API alarms its toggles allow."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.api_5xx[*].dimensions.ApiId) == "abc123"
    error_message = "The 5xx alarm must keep the ApiId dimension from http_api_id."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_errors) == 1 && length(aws_cloudwatch_metric_alarm.lambda_throttles) == 1
    error_message = "A known lambda_function_name with a null override must still create the per function pair."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.standalone_lambda_errors) == 0
    error_message = "The standalone errors alarm must stay off while the per function pair is on."
  }
}

run "null_ids_and_null_overrides_create_nothing_per_function" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.api_5xx) == 0 && length(aws_cloudwatch_metric_alarm.api_integration_latency) == 0
    error_message = "A null http_api_id with a null override must create no API alarms."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_errors) == 0 && length(aws_cloudwatch_metric_alarm.standalone_lambda_errors) == 0
    error_message = "Null function names with null overrides must create no per function Lambda alarms."
  }
}

run "standalone_errors_alarm_with_null_override" {
  command = plan

  variables {
    lambda_errors_alarm_function_name = "example-staging-worker"
    alarms = {
      lambda_account_errors = false
    }
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.standalone_lambda_errors[*].dimensions.FunctionName) == "example-staging-worker"
    error_message = "A known lambda_errors_alarm_function_name with a null override must still create the standalone errors alarm."
  }
}

run "override_false_wins_over_a_known_id" {
  command = plan

  variables {
    http_api_id             = "abc123"
    http_api_alarms_enabled = false
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.api_5xx) == 0
    error_message = "http_api_alarms_enabled false must skip the API alarms even when http_api_id is set."
  }
}

run "override_true_toggle_off_still_subtracts" {
  command = plan

  variables {
    http_api_id             = "abc123"
    http_api_alarms_enabled = true
    alarms = {
      api_5xx = false
    }
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.api_5xx) == 0
    error_message = "alarms.api_5xx false must still drop the 5xx alarm when http_api_alarms_enabled is true."
  }
}

run "http_api_override_true_needs_an_id" {
  command = plan

  variables {
    http_api_alarms_enabled = true
  }

  expect_failures = [var.http_api_alarms_enabled]
}

run "lambda_override_true_needs_a_name" {
  command = plan

  variables {
    lambda_alarms_enabled = true
    alarms = {
      lambda_account_errors    = false
      lambda_account_throttles = false
    }
  }

  expect_failures = [var.lambda_alarms_enabled]
}

run "standalone_override_true_needs_a_name" {
  command = plan

  variables {
    lambda_errors_alarm_enabled = true
    alarms = {
      lambda_account_errors = false
    }
  }

  expect_failures = [var.lambda_errors_alarm_enabled]
}

run "account_errors_validation_honours_an_override_false" {
  command = plan

  variables {
    lambda_function_name  = "example-staging-api"
    lambda_alarms_enabled = false
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_account_errors) == 1 && length(aws_cloudwatch_metric_alarm.lambda_errors) == 0
    error_message = "lambda_alarms_enabled false must let the account wide pair plan beside a set lambda_function_name."
  }
}
