locals {
  topic_name = coalesce(var.sns_topic_name, "${var.name_prefix}-alarms")

  subscriptions = { for e in var.notification_emails : e => e }

  lambda_count = var.lambda_function_name == null ? 0 : 1

  api_5xx_count     = var.http_api_id != null && var.alarms.api_5xx ? 1 : 0
  api_latency_count = var.http_api_id != null && var.alarms.api_integration_latency ? 1 : 0

  dynamodb_table_alarms = var.alarms.dynamodb_throttles ? var.dynamodb_tables : {}

  error_metric_name = coalesce(var.error_metric_name, "${var.name_prefix}-application-errors")

  error_log_groups = var.alarms.application_errors ? var.error_log_groups : {}

  error_alarm_count = length(local.error_log_groups) > 0 ? 1 : 0

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
    var.alarms.telemetry_export_errors && var.telemetry_alarm_enabled && length(var.error_excluded_loggers) > 0
    ? var.error_log_groups
    : {}
  )

  telemetry_metric_name = coalesce(var.telemetry_metric_name, "${var.name_prefix}-telemetry-export-errors")

  telemetry_alarm_count = length(local.telemetry_log_groups) > 0 ? 1 : 0

  standalone_lambda_errors_count = var.lambda_errors_alarm_function_name != null && var.lambda_function_name == null ? 1 : 0

  rate_limit_fail_open_log_groups = (
    var.alarms.rate_limit_failed_open && var.rate_limit_fail_open_alarm
    ? (var.rate_limit_fail_open_log_groups == null ? var.error_log_groups : var.rate_limit_fail_open_log_groups)
    : {}
  )

  rate_limit_fail_open_metric_name = coalesce(var.rate_limit_fail_open_metric_name, "${var.name_prefix}-rate-limit-failed-open")

  rate_limit_fail_open_alarm_count = length(local.rate_limit_fail_open_log_groups) > 0 ? 1 : 0

  alarm_actions = concat([aws_sns_topic.alarms.arn], var.extra_alarm_actions)
  ok_actions    = var.notify_on_ok ? [aws_sns_topic.alarms.arn] : []

  latency_threshold_seconds = format("%g", var.api_latency_threshold_ms / 1000)
}
