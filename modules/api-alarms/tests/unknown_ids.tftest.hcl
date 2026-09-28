provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "unknown_ids_plan_with_literal_overrides" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_ids"
  }

  variables {
    http_api_alarms_enabled     = true
    lambda_alarms_enabled       = true
    lambda_errors_alarm_enabled = true
    alarms = {
      api_integration_latency  = true
      lambda_account_errors    = false
      lambda_account_throttles = false
    }
  }

  assert {
    condition     = output.api_alarm_count == 2
    error_message = "An unknown http_api_id with http_api_alarms_enabled true must plan both API alarms instead of failing with Invalid count argument."
  }

  assert {
    condition     = length(output.lambda_alarm_names) == 2
    error_message = "An unknown lambda_function_name with lambda_alarms_enabled true must plan the per function pair, and the standalone errors alarm must stay off beside it."
  }
}

run "unknown_ids_plan_with_overrides_off" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_ids"
  }

  variables {
    http_api_alarms_enabled     = false
    lambda_alarms_enabled       = false
    lambda_errors_alarm_enabled = false
  }

  assert {
    condition     = output.api_alarm_count == 0
    error_message = "http_api_alarms_enabled false must skip the API alarms even with an http_api_id."
  }

  assert {
    condition     = length(output.lambda_alarm_names) == 2
    error_message = "With every per function override false only the account wide Lambda pair must be planned."
  }
}

run "unknown_standalone_function_plans_with_override" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_ids"
  }

  variables {
    http_api_alarms_enabled     = true
    lambda_alarms_enabled       = false
    lambda_errors_alarm_enabled = true
    alarms = {
      lambda_account_errors = false
    }
  }

  assert {
    condition     = length(output.lambda_alarm_names) == 2
    error_message = "An unknown lambda_errors_alarm_function_name with lambda_errors_alarm_enabled true must plan the standalone errors alarm beside the account wide throttles alarm."
  }
}
