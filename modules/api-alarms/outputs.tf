output "sns_topic_arn" {
  description = "ARN of the alarm topic. Hand it to anything else that should publish to the same notification target."
  value       = aws_sns_topic.alarms.arn
}

output "sns_topic_name" {
  description = "Name of the alarm topic."
  value       = aws_sns_topic.alarms.name
}

output "subscription_arns" {
  description = "Email subscription ARNs keyed by address. A subscription the address has not confirmed reports the ARN as pending confirmation."
  value       = { for k, s in aws_sns_topic_subscription.email : k => s.arn }
}

output "alarm_names" {
  description = "Every alarm name this module created, sorted. Useful for a dashboard or a composite alarm built next to the module."
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_account_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_account_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.api_5xx : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.api_integration_latency : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.standalone_lambda_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.rate_limit_failed_open : a.alarm_name],
  ))
}

output "alarm_arns" {
  description = "Every alarm ARN this module created, sorted."
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_account_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_account_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.api_5xx : a.arn],
    [for a in aws_cloudwatch_metric_alarm.api_integration_latency : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.standalone_lambda_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.rate_limit_failed_open : a.arn],
  ))
}

output "lambda_alarm_names" {
  description = "Names of every AWS/Lambda metric alarm the module created: the per function errors and throttles pair when lambda_function_name is set, the account wide pair when the alarms toggles are on, and the single errors alarm when only lambda_errors_alarm_function_name is. Empty when none of those inputs is set."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_account_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_account_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.standalone_lambda_errors : a.alarm_name],
  )
}










output "api_alarm_names" {
  description = "Names of the two HTTP API alarms, empty when http_api_id is null."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.api_5xx : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.api_integration_latency : a.alarm_name],
  )
}

output "dynamodb_alarm_names" {
  description = "DynamoDB throttle alarm names keyed by the dynamodb_tables key that produced them."
  value       = { for k, a in aws_cloudwatch_metric_alarm.dynamodb_throttles : k => a.alarm_name }
}

output "dynamodb_aggregate_alarm_name" {
  description = "Name of the aggregate DynamoDB throttle alarm, null when dynamodb_aggregate_alarm is false."
  value       = one(aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles[*].alarm_name)
}

output "error_alarm_name" {
  description = "Name of the application errors alarm, null when error_log_groups is empty."
  value       = one(aws_cloudwatch_metric_alarm.errors[*].alarm_name)
}

output "error_metric_filter_names" {
  description = "Metric filter names keyed by the error_log_groups key that produced them. Empty when error_log_groups is empty."
  value       = { for k, f in aws_cloudwatch_log_metric_filter.errors : k => f.name }
}

output "error_metric" {
  description = "Namespace and name of the metric every error filter publishes to, so a dashboard or a composite alarm can graph the same series the alarm watches. Both fields are null when error_log_groups is empty."
  value = {
    namespace = local.error_alarm_count > 0 ? var.error_metric_namespace : null
    name      = local.error_alarm_count > 0 ? local.error_metric_name : null
  }
}

output "error_filter_pattern" {
  description = "The filter pattern the error metric filters were created with, whether it was built from error_excluded_loggers or supplied literally. Read it to confirm what the alarm actually matches without opening the CloudWatch console."
  value       = local.error_filter_pattern
}

output "telemetry_alarm_name" {
  description = "Name of the telemetry export errors alarm, null when telemetry_alarm_enabled is false, error_excluded_loggers is empty, or there are no log groups to watch."
  value       = one(aws_cloudwatch_metric_alarm.telemetry_errors[*].alarm_name)
}

output "telemetry_metric_filter_names" {
  description = "Telemetry metric filter names keyed by the error_log_groups key that produced them. Empty when the telemetry alarm is off."
  value       = { for k, f in aws_cloudwatch_log_metric_filter.telemetry_errors : k => f.name }
}

output "telemetry_metric" {
  description = "Namespace and name of the metric every telemetry filter publishes to, so a dashboard can graph the dropped traces alongside the application errors. Both fields are null when the alarm is off."
  value = {
    namespace = local.telemetry_alarm_count > 0 ? var.error_metric_namespace : null
    name      = local.telemetry_alarm_count > 0 ? local.telemetry_metric_name : null
  }
}

output "rate_limit_fail_open_alarm_name" {
  description = "Name of the rate limit fail open alarm, null when rate_limit_fail_open_alarm is false or there are no log groups to watch."
  value       = one(aws_cloudwatch_metric_alarm.rate_limit_failed_open[*].alarm_name)
}

output "rate_limit_fail_open_metric_filter_names" {
  description = "Fail open metric filter names keyed by the log group key that produced them. Empty when rate_limit_fail_open_alarm is false."
  value       = { for k, f in aws_cloudwatch_log_metric_filter.rate_limit_failed_open : k => f.name }
}

output "rate_limit_fail_open_metric" {
  description = "Namespace and name of the metric every fail open filter publishes to, so a dashboard or a composite alarm can graph the same series the alarm watches. Both fields are null when the alarm is off."
  value = {
    namespace = local.rate_limit_fail_open_alarm_count > 0 ? var.error_metric_namespace : null
    name      = local.rate_limit_fail_open_alarm_count > 0 ? local.rate_limit_fail_open_metric_name : null
  }
}

output "lambda_account_errors_alarm_arn" {
  description = "ARN of the account wide Lambda errors alarm, null when alarms.lambda_account_errors is false. The alarm watches AWS/Lambda Errors with no dimensions, so it covers every function in the account for one billed metric however many functions there are."
  value       = one(aws_cloudwatch_metric_alarm.lambda_account_errors[*].arn)
}

output "lambda_account_throttles_alarm_arn" {
  description = "ARN of the account wide Lambda throttles alarm, null when alarms.lambda_account_throttles is false."
  value       = one(aws_cloudwatch_metric_alarm.lambda_account_throttles[*].arn)
}
