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
