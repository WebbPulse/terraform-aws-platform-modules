locals {
  topic_name = coalesce(var.sns_topic_name, "${var.name_prefix}-alarms")

  # The addresses are the for_each keys, so a removed address destroys only its own subscription.
  subscriptions = { for e in var.notification_emails : e => e }

  lambda_count = var.lambda_function_name == null ? 0 : 1
  api_count    = var.http_api_id == null ? 0 : 1

  # Every filter in error_log_groups publishes to this one metric, with no dimensions, so the
  # alarm below is a plain metric alarm whose Sum is the total across all of them. See the README
  # section "Errors from the logs" for why the metric carries no dimensions.
  error_metric_name = coalesce(var.error_metric_name, "${var.name_prefix}-application-errors")

  # The alarm exists only when there is at least one log group to feed it. An empty map is the
  # default, which is what keeps the feature off for consumers that pass nothing.
  error_alarm_count = length(var.error_log_groups) > 0 ? 1 : 0

  # The Lambda Errors alarm already exists whenever lambda_function_name is set, so this second
  # input only has something to create when the module was not given a function name. That keeps
  # "<name_prefix>-lambda-errors" a single resource with a single name, whichever input asked
  # for it, rather than two resources racing for the same alarm name.
  standalone_lambda_errors_count = var.lambda_errors_alarm_function_name != null && var.lambda_function_name == null ? 1 : 0

  alarm_actions = concat([aws_sns_topic.alarms.arn], var.extra_alarm_actions)
  ok_actions    = var.notify_on_ok ? [aws_sns_topic.alarms.arn] : []

  # Rendered into the latency alarm description. 10000 ms reads as "10 s", 1500 ms as "1.5 s".
  latency_threshold_seconds = format("%g", var.api_latency_threshold_ms / 1000)
}
