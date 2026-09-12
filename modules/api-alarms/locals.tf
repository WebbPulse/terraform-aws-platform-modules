locals {
  topic_name = coalesce(var.sns_topic_name, "${var.name_prefix}-alarms")

  subscriptions = { for e in var.notification_emails : e => e }

  lambda_count = var.lambda_function_name == null ? 0 : 1
  api_count    = var.http_api_id == null ? 0 : 1

  lambda_aggregate_chunk_size = 10

  lambda_aggregate_chunks = var.lambda_aggregate_alarm ? chunklist(var.lambda_function_names, local.lambda_aggregate_chunk_size) : []

  lambda_aggregate_count = length(local.lambda_aggregate_chunks)

  lambda_aggregate_metrics = [
    for chunk in local.lambda_aggregate_chunks : {
      for i, name in chunk : "m${i}" => name
    }
  ]

  lambda_aggregate_expressions = [
    for chunk in local.lambda_aggregate_chunks : join(" + ", [for i, _ in chunk : "m${i}"])
  ]

  lambda_aggregate_name_suffixes = [
    for i, _ in local.lambda_aggregate_chunks : i == 0 ? "" : "-${i + 1}"
  ]

  error_metric_name = coalesce(var.error_metric_name, "${var.name_prefix}-application-errors")

  error_alarm_count = length(var.error_log_groups) > 0 ? 1 : 0

  excluded_logger_clauses = [
    for l in var.error_excluded_loggers : "$.logger != \"${l}\""
  ]

  included_logger_clauses = [
    for l in var.error_excluded_loggers : "$.logger = \"${l}\""
  ]

  built_error_filter_pattern = (
    length(var.error_excluded_loggers) == 0
    ? "{ $.level = \"ERROR\" }"
    : "{ $.level = \"ERROR\" && ($.logger NOT EXISTS || (${join(" && ", local.excluded_logger_clauses)})) }"
  )

  error_filter_pattern = coalesce(var.error_filter_pattern, local.built_error_filter_pattern)

  telemetry_filter_pattern = "{ $.level = \"ERROR\" && (${join(" || ", local.included_logger_clauses)}) }"

  telemetry_log_groups = (
    var.telemetry_alarm_enabled && length(var.error_excluded_loggers) > 0
    ? var.error_log_groups
    : {}
  )

  telemetry_metric_name = coalesce(var.telemetry_metric_name, "${var.name_prefix}-telemetry-export-errors")

  telemetry_alarm_count = length(local.telemetry_log_groups) > 0 ? 1 : 0

  standalone_lambda_errors_count = var.lambda_errors_alarm_function_name != null && var.lambda_function_name == null ? 1 : 0

  rate_limit_fail_open_log_groups = (
    var.rate_limit_fail_open_alarm
    ? (var.rate_limit_fail_open_log_groups == null ? var.error_log_groups : var.rate_limit_fail_open_log_groups)
    : {}
  )

  rate_limit_fail_open_metric_name = coalesce(var.rate_limit_fail_open_metric_name, "${var.name_prefix}-rate-limit-failed-open")

  rate_limit_fail_open_alarm_count = length(local.rate_limit_fail_open_log_groups) > 0 ? 1 : 0

  alarm_actions = concat([aws_sns_topic.alarms.arn], var.extra_alarm_actions)
  ok_actions    = var.notify_on_ok ? [aws_sns_topic.alarms.arn] : []

  latency_threshold_seconds = format("%g", var.api_latency_threshold_ms / 1000)
}
