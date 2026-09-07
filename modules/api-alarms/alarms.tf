# --- Lambda ---------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = local.lambda_count

  alarm_name          = "${var.name_prefix}-lambda-errors"
  alarm_description   = "Lambda API reported invocation errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.lambda_function_name }
  statistic           = "Sum"
  period              = var.lambda_errors_period
  evaluation_periods  = var.lambda_errors_evaluation_periods
  threshold           = var.lambda_errors_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  count = local.lambda_count

  alarm_name          = "${var.name_prefix}-lambda-throttles"
  alarm_description   = "Lambda API invocations were throttled"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = var.lambda_function_name }
  statistic           = "Sum"
  period              = var.lambda_throttles_period
  evaluation_periods  = var.lambda_throttles_evaluation_periods
  threshold           = var.lambda_throttles_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags
}

# --- Lambda, aggregated over a function per domain ---------------------------------------------
#
# An application split into a function per domain wants one Errors alarm and one Throttles alarm
# for the whole estate, not a pair per function. Each of these is a metric math alarm: one
# metric_query per name in the group carrying that function's FunctionName dimension with
# return_data = false, plus a SUM expression that returns data to the alarm.
#
# Summing named metrics rather than alarming on AWS/Lambda Errors with no FunctionName dimension
# is the deliberate choice. A dimensionless AWS/Lambda alarm is account wide, so it also counts
# the access gate's authorizer function and anything else in the account, and the threshold stops
# meaning what it says. These alarms cover exactly the listed functions.
#
# A CloudWatch alarm's metric math expression may reference at most 10 metrics. That used to cap
# lambda_function_names at 10 names; it now chunks the list into groups of at most 10 instead, one
# alarm pair per group. Group 0 keeps the unsuffixed alarm names and the [0] addresses, so a
# consumer at 10 or fewer functions plans nothing. See locals.tf for why count survives here.
#
# Within a group the alarm names carry no function name, so adding a domain changes the expression
# on an existing alarm rather than creating another alarm to subscribe and document, right up until
# the group fills and the next one opens.

resource "aws_cloudwatch_metric_alarm" "lambda_aggregate_errors" {
  count = local.lambda_aggregate_count

  alarm_name          = "${var.name_prefix}-lambda-errors-aggregate${local.lambda_aggregate_name_suffixes[count.index]}"
  alarm_description   = "Lambda invocation errors across ${length(local.lambda_aggregate_chunks[count.index])} function${length(local.lambda_aggregate_chunks[count.index]) == 1 ? "" : "s"}"
  evaluation_periods  = var.lambda_aggregate_evaluation_periods
  threshold           = var.lambda_aggregate_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags

  metric_query {
    id          = "errors"
    expression  = local.lambda_aggregate_expressions[count.index]
    label       = "Errors"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.lambda_aggregate_metrics[count.index]

    content {
      id          = metric_query.key
      label       = metric_query.value
      return_data = false

      metric {
        namespace   = "AWS/Lambda"
        metric_name = "Errors"
        dimensions  = { FunctionName = metric_query.value }
        stat        = "Sum"
        period      = var.lambda_aggregate_period
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_aggregate_throttles" {
  count = local.lambda_aggregate_count

  alarm_name          = "${var.name_prefix}-lambda-throttles-aggregate${local.lambda_aggregate_name_suffixes[count.index]}"
  alarm_description   = "Lambda invocations throttled across ${length(local.lambda_aggregate_chunks[count.index])} function${length(local.lambda_aggregate_chunks[count.index]) == 1 ? "" : "s"}"
  evaluation_periods  = var.lambda_aggregate_evaluation_periods
  threshold           = var.lambda_aggregate_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags

  metric_query {
    id          = "throttles"
    expression  = local.lambda_aggregate_expressions[count.index]
    label       = "Throttles"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.lambda_aggregate_metrics[count.index]

    content {
      id          = metric_query.key
      label       = metric_query.value
      return_data = false

      metric {
        namespace   = "AWS/Lambda"
        metric_name = "Throttles"
        dimensions  = { FunctionName = metric_query.value }
        stat        = "Sum"
        period      = var.lambda_aggregate_period
      }
    }
  }
}

# --- HTTP API -------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  count = local.api_count

  alarm_name          = "${var.name_prefix}-api-5xx"
  alarm_description   = "HTTP API returned 5xx responses"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = var.http_api_id }
  statistic           = "Sum"
  period              = var.api_5xx_period
  evaluation_periods  = var.api_5xx_evaluation_periods
  threshold           = var.api_5xx_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_integration_latency" {
  count = local.api_count

  alarm_name          = "${var.name_prefix}-api-integration-latency-${var.api_latency_statistic}"
  alarm_description   = "HTTP API ${var.api_latency_statistic} integration latency above ${local.latency_threshold_seconds} s"
  namespace           = "AWS/ApiGateway"
  metric_name         = "IntegrationLatency"
  dimensions          = { ApiId = var.http_api_id }
  extended_statistic  = var.api_latency_statistic
  period              = var.api_latency_period
  evaluation_periods  = var.api_latency_evaluation_periods
  threshold           = var.api_latency_threshold_ms
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags
}

# --- DynamoDB -------------------------------------------------------------------------------
# One alarm per table on read plus write throttle events. The two metrics are summed by a metric
# math expression rather than alarmed separately, so a table raises one alarm however it throttles.

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  for_each = var.dynamodb_tables

  alarm_name          = "${each.value}-throttles"
  alarm_description   = "DynamoDB read or write throttle events on ${each.value}"
  evaluation_periods  = var.dynamodb_throttles_evaluation_periods
  threshold           = var.dynamodb_throttles_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags

  metric_query {
    id          = "throttles"
    expression  = "reads + writes"
    label       = "ThrottleEvents"
    return_data = true
  }

  metric_query {
    id = "reads"
    metric {
      namespace   = "AWS/DynamoDB"
      metric_name = "ReadThrottleEvents"
      dimensions  = { TableName = each.value }
      stat        = "Sum"
      period      = var.dynamodb_throttles_period
    }
  }

  metric_query {
    id = "writes"
    metric {
      namespace   = "AWS/DynamoDB"
      metric_name = "WriteThrottleEvents"
      dimensions  = { TableName = each.value }
      stat        = "Sum"
      period      = var.dynamodb_throttles_period
    }
  }
}

# One alarm for the whole environment, on throttled requests across every table in the account and
# Region. It is a single CloudWatch Metrics Insights query, which is the most an alarm can carry:
# PutMetricAlarm rejects an alarm holding two Metrics Insights queries with "Invalid metrics list",
# so ReadThrottleEvents and WriteThrottleEvents cannot be summed here the way the per table alarms
# sum them. ThrottledRequests is the one metric covering both directions on its own.
#
# SCHEMA("AWS/DynamoDB", TableName, Operation) matches the series ThrottledRequests is published
# with. Those are per table and per operation, so the SUM is every throttled request in the
# account whatever table or operation it hit.
#
# The query is re-resolved on every evaluation, so a table created after the apply is covered
# without a Terraform change and a deleted table drops out on its own.

resource "aws_cloudwatch_metric_alarm" "dynamodb_aggregate_throttles" {
  count = var.dynamodb_aggregate_alarm ? 1 : 0

  alarm_name          = "${var.name_prefix}-dynamodb-throttles"
  alarm_description   = "DynamoDB throttled requests on any table in the account"
  evaluation_periods  = var.dynamodb_aggregate_evaluation_periods
  threshold           = var.dynamodb_aggregate_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags

  metric_query {
    id          = "throttles"
    expression  = "SELECT SUM(ThrottledRequests) FROM SCHEMA(\"AWS/DynamoDB\", TableName, Operation)"
    label       = "ThrottledRequests"
    period      = var.dynamodb_aggregate_period
    return_data = true
  }
}
