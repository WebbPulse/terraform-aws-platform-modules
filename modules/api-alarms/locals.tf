locals {
  topic_name = coalesce(var.sns_topic_name, "${var.name_prefix}-alarms")

  # The addresses are the for_each keys, so a removed address destroys only its own subscription.
  subscriptions = { for e in var.notification_emails : e => e }

  lambda_count = var.lambda_function_name == null ? 0 : 1
  api_count    = var.http_api_id == null ? 0 : 1

  alarm_actions = concat([aws_sns_topic.alarms.arn], var.extra_alarm_actions)
  ok_actions    = var.notify_on_ok ? [aws_sns_topic.alarms.arn] : []

  # Rendered into the latency alarm description. 10000 ms reads as "10 s", 1500 ms as "1.5 s".
  latency_threshold_seconds = format("%g", var.api_latency_threshold_ms / 1000)
}
