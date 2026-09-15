variables {
  name_prefix = "example-staging"
  http_api_id = "abc123"
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

run "default_toggles_give_the_lean_set" {
  command = plan

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_account_errors[*].alarm_name) == "example-staging-lambda-errors"
    error_message = "The account wide errors alarm must be created by default and named <name_prefix>-lambda-errors."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_account_throttles[*].alarm_name) == "example-staging-lambda-throttles"
    error_message = "The account wide throttles alarm must be created by default and named <name_prefix>-lambda-throttles."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.api_5xx) == 1
    error_message = "The API 5xx alarm is part of the lean set and must be created by default."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.api_integration_latency) == 0
    error_message = "The integration latency alarm is outside the lean set and must be off by default."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles) == 0
    error_message = "The DynamoDB throttles alarm is outside the lean set and must be off by default."
  }
}

run "account_alarms_carry_no_dimension_so_they_bill_one_metric" {
  command = plan

  assert {
    condition     = length(coalesce(one(aws_cloudwatch_metric_alarm.lambda_account_errors[*].dimensions), {})) == 0
    error_message = "The account wide errors alarm must carry no dimensions: a FunctionName dimension would scope it to one function."
  }

  assert {
    condition     = length(one(aws_cloudwatch_metric_alarm.lambda_account_errors[*].metric_query)) == 0
    error_message = "The account wide errors alarm must be a plain metric alarm, not metric math: metric math bills per referenced metric."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_account_errors[*].namespace) == "AWS/Lambda"
    error_message = "The account wide errors alarm must watch the AWS/Lambda namespace."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_account_errors[*].metric_name) == "Errors"
    error_message = "The account wide errors alarm must watch the Errors metric."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_account_throttles[*].metric_name) == "Throttles"
    error_message = "The account wide throttles alarm must watch the Throttles metric."
  }
}

run "every_toggle_off_creates_no_alarms_but_keeps_the_topic" {
  command = plan

  variables {
    alarms = {
      api_5xx                  = false
      lambda_account_errors    = false
      lambda_account_throttles = false
    }
  }

  assert {
    condition     = length(output.alarm_names) == 0
    error_message = "With every toggle off the module must create no metric alarms."
  }

  assert {
    condition     = aws_sns_topic.alarms.name == "example-staging-alarms"
    error_message = "The SNS topic is never gated: anything else publishing to it must keep working."
  }
}

run "toggles_can_turn_the_richer_set_back_on" {
  command = plan

  variables {
    alarms = {
      api_integration_latency = true
      dynamodb_throttles      = true
    }
    dynamodb_aggregate_alarm = true
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.api_integration_latency) == 1
    error_message = "alarms.api_integration_latency = true must bring the latency alarm back."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles) == 1
    error_message = "alarms.dynamodb_throttles = true with dynamodb_aggregate_alarm must bring the DynamoDB alarm back."
  }
}
