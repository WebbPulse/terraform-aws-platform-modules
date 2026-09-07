# Chunking the aggregate Lambda alarms past the CloudWatch metric math ceiling.
#
# A CloudWatch alarm's metric math expression may reference at most 10 metrics. Up to and including
# v2.1.0 that was a hard cap on lambda_function_names. It is now a chunk size instead: the list is
# split into groups of at most 10, in list order, and each group gets its own errors and throttles
# alarm pair.
#
# The assertions below pin the two things a consumer depends on:
#
#   * A list of 10 or fewer names produces exactly what v2.1.0 produced. Same alarm names, same
#     count, same expression, and, because the resources stayed on count, the same addresses
#     lambda_aggregate_errors[0] and lambda_aggregate_throttles[0]. That is the zero-change plan.
#   * A longer list chunks in order, group 0 keeps the unsuffixed name, and later groups are
#     numbered from 2.

variables {
  name_prefix            = "example-staging"
  lambda_aggregate_alarm = true

  # Twelve names, which is two groups: ten then two.
  lambda_function_names = [
    "example-staging-d01",
    "example-staging-d02",
    "example-staging-d03",
    "example-staging-d04",
    "example-staging-d05",
    "example-staging-d06",
    "example-staging-d07",
    "example-staging-d08",
    "example-staging-d09",
    "example-staging-d10",
    "example-staging-d11",
    "example-staging-d12",
  ]
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

# --- Twelve names: two groups ------------------------------------------------------------------

run "twelve_names_make_two_alarm_pairs" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors) == 2
    error_message = "Twelve function names must chunk into two aggregate errors alarms."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles) == 2
    error_message = "Twelve function names must chunk into two aggregate throttles alarms."
  }

  # Group 0 keeps the v2.1.0 name; group 1 is numbered from 2 so it reads as the second group.
  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].alarm_name == "example-staging-lambda-errors-aggregate"
    error_message = "The first group's errors alarm must keep the unsuffixed name."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_errors[1].alarm_name == "example-staging-lambda-errors-aggregate-2"
    error_message = "The second group's errors alarm must be suffixed -2."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[0].alarm_name == "example-staging-lambda-throttles-aggregate"
    error_message = "The first group's throttles alarm must keep the unsuffixed name."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[1].alarm_name == "example-staging-lambda-throttles-aggregate-2"
    error_message = "The second group's throttles alarm must be suffixed -2."
  }

  # No alarm may exceed the ceiling: 10 contributing metrics plus the one expression query.
  assert {
    condition = alltrue([
      for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors :
      length([for q in a.metric_query : q if !q.return_data]) <= 10
    ])
    error_message = "No aggregate alarm may reference more than 10 metrics."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].metric_query) == 11
    error_message = "The first group must hold ten contributing queries plus the expression."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[1].metric_query) == 3
    error_message = "The second group must hold the remaining two queries plus the expression."
  }
}

run "chunks_split_in_list_order_and_cover_every_name_once" {
  command = plan

  # Group 0 is the first ten names, in order.
  assert {
    condition = jsonencode([
      for q in aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].metric_query : q.label if !q.return_data
    ]) == jsonencode(slice(var.lambda_function_names, 0, 10))
    error_message = "The first group must be the first ten names in lambda_function_names order."
  }

  assert {
    condition = jsonencode([
      for q in aws_cloudwatch_metric_alarm.lambda_aggregate_errors[1].metric_query : q.label if !q.return_data
    ]) == jsonencode(slice(var.lambda_function_names, 10, 12))
    error_message = "The second group must be the remaining names in lambda_function_names order."
  }

  # Every listed function is covered exactly once across the groups: no gaps, no double counting.
  assert {
    condition = sort(flatten([
      for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors :
      [for q in a.metric_query : one(values(one(q.metric).dimensions)) if !q.return_data]
    ])) == sort(var.lambda_function_names)
    error_message = "Every function must contribute exactly one metric across the groups."
  }
}

run "metric_ids_restart_at_m0_in_every_chunk" {
  command = plan

  assert {
    condition = one([
      for q in aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].metric_query : q.expression if q.return_data
    ]) == "m0 + m1 + m2 + m3 + m4 + m5 + m6 + m7 + m8 + m9"
    error_message = "The first group's expression must sum m0 through m9."
  }

  # The ids are scoped to the alarm they appear in, so the second group starts over at m0 rather
  # than carrying a global offset. That keeps a full group byte-identical to the same ten names
  # passed on their own.
  assert {
    condition = one([
      for q in aws_cloudwatch_metric_alarm.lambda_aggregate_errors[1].metric_query : q.expression if q.return_data
    ]) == "m0 + m1"
    error_message = "The second group's metric ids must restart at m0."
  }

  assert {
    condition = one([
      for q in aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[1].metric_query : q.expression if q.return_data
    ]) == "m0 + m1"
    error_message = "The throttles alarm must chunk and number its ids the same way as the errors alarm."
  }

  # Each alarm's description counts its own group, not the whole estate.
  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_errors[1].alarm_description == "Lambda invocation errors across 2 functions"
    error_message = "Each aggregate alarm must describe the number of functions in its own group."
  }
}

run "outputs_report_every_chunk" {
  command = plan

  assert {
    condition = output.lambda_aggregate_errors_alarm_names == [
      "example-staging-lambda-errors-aggregate",
      "example-staging-lambda-errors-aggregate-2",
    ]
    error_message = "lambda_aggregate_errors_alarm_names must list one name per group in chunk order."
  }

  assert {
    condition = output.lambda_aggregate_throttles_alarm_names == [
      "example-staging-lambda-throttles-aggregate",
      "example-staging-lambda-throttles-aggregate-2",
    ]
    error_message = "lambda_aggregate_throttles_alarm_names must list one name per group in chunk order."
  }

  # The plural names output carries every alarm: errors first, then throttles, each in chunk order.
  assert {
    condition     = length(output.lambda_aggregate_alarm_names) == 4
    error_message = "lambda_aggregate_alarm_names must carry all four alarms when there are two groups."
  }

  assert {
    condition     = jsonencode(output.lambda_aggregate_function_name_chunks) == jsonencode([slice(var.lambda_function_names, 0, 10), slice(var.lambda_function_names, 10, 12)])
    error_message = "lambda_aggregate_function_name_chunks must report the grouping the alarms used."
  }

  # The pre-chunking singular ARN outputs still resolve on a list this long rather than failing the
  # way one() would on more than one element; that they evaluate at all is what this run proves,
  # since an output that raised would fail the run. The ARN values themselves are unknown until
  # apply, so what is checkable here is the shape of the plural outputs beside them.
  assert {
    condition     = length(output.lambda_aggregate_errors_alarm_arns) == 2 && length(output.lambda_aggregate_throttles_alarm_arns) == 2
    error_message = "The plural ARN outputs must carry one entry per group."
  }
}

# --- Five names: one group, byte-identical to v2.1.0 -------------------------------------------
#
# This is the compatibility guarantee. Five names is the shape an existing consumer runs, and it
# must produce one alarm pair at the same addresses, with the same names and the same expression
# v2.1.0 produced. Because the resources are still count-indexed, [0] here is the same address the
# existing state holds, so the plan is empty and no moved block is needed.

run "five_names_make_one_unsuffixed_pair_at_index_zero" {
  command = plan

  variables {
    lambda_function_names = [
      "example-staging-content",
      "example-staging-resume",
      "example-staging-identity",
      "example-staging-public",
      "example-staging-admin",
    ]
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors) == 1 && length(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles) == 1
    error_message = "Five function names must stay one group, so one alarm pair at index 0."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].alarm_name == "example-staging-lambda-errors-aggregate"
    error_message = "A single group must carry no numeric suffix: that name is what v2.1.0 created."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[0].alarm_name == "example-staging-lambda-throttles-aggregate"
    error_message = "A single group must carry no numeric suffix on the throttles alarm either."
  }

  assert {
    condition = one([
      for q in aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].metric_query : q.expression if q.return_data
    ]) == "m0 + m1 + m2 + m3 + m4"
    error_message = "A single group's expression must be the same SUM v2.1.0 built."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].metric_query) == 6
    error_message = "Five contributing queries plus the expression, exactly as before."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].alarm_description == "Lambda invocation errors across 5 functions"
    error_message = "A single group's description must count the whole list, as it did before chunking."
  }

  # The outputs an existing consumer already wires stay the shape they were: two names, errors
  # first, and a singular ARN per alarm.
  assert {
    condition = output.lambda_aggregate_alarm_names == [
      "example-staging-lambda-errors-aggregate",
      "example-staging-lambda-throttles-aggregate",
    ]
    error_message = "lambda_aggregate_alarm_names must be unchanged for a list of ten or fewer."
  }
}

# Exactly ten, the old ceiling, is still one group and still one pair. This is the case that
# decided the chunk boundary: CarModPicker's nine domain functions plus the monolith.
run "exactly_ten_names_stay_one_group" {
  command = plan

  variables {
    lambda_function_names = [
      "example-staging-d01",
      "example-staging-d02",
      "example-staging-d03",
      "example-staging-d04",
      "example-staging-d05",
      "example-staging-d06",
      "example-staging-d07",
      "example-staging-d08",
      "example-staging-d09",
      "example-staging-monolith",
    ]
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors) == 1
    error_message = "Ten names is the chunk size, so it must stay one group and not spill into a second."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].alarm_name == "example-staging-lambda-errors-aggregate"
    error_message = "Ten names must keep the unsuffixed alarm name."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[0].metric_query) == 11
    error_message = "Ten contributing queries plus the expression is the CloudWatch maximum."
  }
}

# Twenty-one names is three groups: ten, ten, one. The trailing group of one proves the singular
# wording in the alarm description survives chunking.
run "twenty_one_names_make_three_groups" {
  command = plan

  variables {
    lambda_function_names = [
      "example-staging-d01", "example-staging-d02", "example-staging-d03", "example-staging-d04",
      "example-staging-d05", "example-staging-d06", "example-staging-d07", "example-staging-d08",
      "example-staging-d09", "example-staging-d10", "example-staging-d11", "example-staging-d12",
      "example-staging-d13", "example-staging-d14", "example-staging-d15", "example-staging-d16",
      "example-staging-d17", "example-staging-d18", "example-staging-d19", "example-staging-d20",
      "example-staging-d21",
    ]
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.lambda_aggregate_errors) == 3
    error_message = "Twenty-one names must chunk into three groups."
  }

  assert {
    condition = [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors : a.alarm_name] == [
      "example-staging-lambda-errors-aggregate",
      "example-staging-lambda-errors-aggregate-2",
      "example-staging-lambda-errors-aggregate-3",
    ]
    error_message = "Groups past the first must be numbered from 2 upward."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_aggregate_errors[2].alarm_description == "Lambda invocation errors across 1 function"
    error_message = "A group of one must describe one function, not one functions."
  }

  assert {
    condition = one([
      for q in aws_cloudwatch_metric_alarm.lambda_aggregate_errors[2].metric_query : q.expression if q.return_data
    ]) == "m0"
    error_message = "A group of one must sum a single id."
  }
}
