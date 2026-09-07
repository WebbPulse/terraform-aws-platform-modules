# The aggregate Lambda alarms: two alarms summing AWS/Lambda Errors and Throttles across a function
# per domain, instead of a per function pair. The assertions below pin the three things the shape
# depends on: the alarm names carry no function name, every listed function contributes exactly one
# metric_query that returns no data, and the one query that does return data is the SUM over them.

variables {
  name_prefix = "example-staging"

  lambda_function_names = [
    "example-staging-content",
    "example-staging-resume",
    "example-staging-identity",
    "example-staging-public",
  ]

  lambda_aggregate_alarm = true
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

run "aggregate_alarms_are_created_and_named_without_function_names" {
  command = plan

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].alarm_name) == "example-staging-lambda-errors-aggregate"
    error_message = "The aggregate errors alarm name must be <name_prefix>-lambda-errors-aggregate and must not embed a function name."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[*].alarm_name) == "example-staging-lambda-throttles-aggregate"
    error_message = "The aggregate throttles alarm name must be <name_prefix>-lambda-throttles-aggregate and must not embed a function name."
  }

  # The per function alarms are the other form of the input and must not appear alongside these.
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_errors) == 0 && length(aws_cloudwatch_metric_alarm.lambda_throttles) == 0
    error_message = "lambda_function_names must not create the per function alarm pair: that is what lambda_function_name is for."
  }
}

run "errors_alarm_is_metric_math_over_every_listed_function" {
  command = plan

  # Four functions plus the expression that sums them.
  assert {
    condition     = length(one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].metric_query)) == 5
    error_message = "Expected one metric_query per function plus one expression query."
  }

  assert {
    condition     = one([for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].metric_query) : q.expression if q.return_data]) == "m0 + m1 + m2 + m3"
    error_message = "The single data-returning query must be the SUM over every function's metric id."
  }

  assert {
    condition     = length([for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].metric_query) : q if q.return_data]) == 1
    error_message = "Exactly one metric_query may return data to the alarm."
  }

  assert {
    condition = alltrue([
      for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].metric_query) :
      one(q.metric).metric_name == "Errors" && one(q.metric).namespace == "AWS/Lambda" && one(q.metric).stat == "Sum"
      if !q.return_data
    ])
    error_message = "Every contributing query must be AWS/Lambda Errors summed."
  }

  # Each contributing query carries its own FunctionName, which is what makes the alarm cover the
  # listed functions rather than every function in the account.
  assert {
    condition = toset(flatten([
      for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].metric_query) :
      values(one(q.metric).dimensions) if !q.return_data
    ])) == toset(var.lambda_function_names)
    error_message = "The FunctionName dimensions must be exactly the functions in lambda_function_names."
  }

  # The function name rides in the label, so the notification still names the per function series.
  assert {
    condition = toset([
      for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].metric_query) : q.label if !q.return_data
    ]) == toset(var.lambda_function_names)
    error_message = "Each contributing query must be labelled with its function name."
  }
}

run "throttles_alarm_is_the_same_shape_on_the_throttles_metric" {
  command = plan

  assert {
    condition = alltrue([
      for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[*].metric_query) :
      one(q.metric).metric_name == "Throttles"
      if !q.return_data
    ])
    error_message = "Every contributing query on the throttles alarm must be AWS/Lambda Throttles."
  }

  assert {
    condition     = one([for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[*].metric_query) : q.expression if q.return_data]) == "m0 + m1 + m2 + m3"
    error_message = "The throttles alarm must sum the same set of functions as the errors alarm."
  }
}

run "shared_period_threshold_and_evaluation_reach_both_alarms" {
  command = plan

  variables {
    lambda_aggregate_threshold          = 5
    lambda_aggregate_period             = 60
    lambda_aggregate_evaluation_periods = 3
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].threshold) == 5 && one(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[*].threshold) == 5
    error_message = "lambda_aggregate_threshold must reach both aggregate alarms."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].evaluation_periods) == 3
    error_message = "lambda_aggregate_evaluation_periods did not reach the errors alarm."
  }

  assert {
    condition = alltrue([
      for q in one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].metric_query) :
      one(q.metric).period == 60
      if !q.return_data
    ])
    error_message = "lambda_aggregate_period must reach every contributing metric."
  }
}

# The backward-compatibility guarantee: the one function form is untouched, and the aggregate
# resources have a count of 0 unless asked for.
run "the_one_function_form_still_creates_exactly_the_old_pair" {
  command = plan

  variables {
    lambda_function_names  = []
    lambda_aggregate_alarm = false
    lambda_function_name   = "example-staging-api"
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_errors[*].alarm_name) == "example-staging-lambda-errors"
    error_message = "The per function errors alarm name must not have changed."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_errors[*].dimensions).FunctionName == "example-staging-api"
    error_message = "The per function errors alarm must still be a plain dimensioned alarm."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.lambda_throttles[*].alarm_name) == "example-staging-lambda-throttles"
    error_message = "The per function throttles alarm name must not have changed."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors) == 0 && length(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles) == 0
    error_message = "The aggregate alarms must not exist unless lambda_aggregate_alarm is true."
  }
}

run "no_lambda_alarms_at_all_when_neither_form_is_set" {
  command = plan

  variables {
    lambda_function_names  = []
    lambda_aggregate_alarm = false
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_errors) == 0 && length(aws_cloudwatch_metric_alarm.lambda_throttles) == 0 && length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors) == 0 && length(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles) == 0
    error_message = "Neither function input set must mean no AWS/Lambda alarms."
  }
}
