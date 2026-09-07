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
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.api_5xx : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.api_integration_latency : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.standalone_lambda_errors : a.alarm_name],
  ))
}

output "alarm_arns" {
  description = "Every alarm ARN this module created, sorted."
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.api_5xx : a.arn],
    [for a in aws_cloudwatch_metric_alarm.api_integration_latency : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.standalone_lambda_errors : a.arn],
  ))
}

output "lambda_alarm_names" {
  description = "Names of every AWS/Lambda metric alarm the module created: the per function errors and throttles pair when lambda_function_name is set, the aggregate pair when lambda_aggregate_alarm is true, and the single errors alarm when only lambda_errors_alarm_function_name is. Empty when none of those inputs is set."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_throttles : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.standalone_lambda_errors : a.alarm_name],
  )
}

output "lambda_aggregate_alarm_names" {
  description = "Names of the two aggregate Lambda alarms, the errors one first. Empty when lambda_aggregate_alarm is false."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_throttles : a.alarm_name],
  )
}

output "lambda_aggregate_alarm_arns" {
  description = "ARNs of the two aggregate Lambda alarms, the errors one first, for a composite alarm or a dashboard built next to the module. Empty when lambda_aggregate_alarm is false."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_aggregate_throttles : a.arn],
  )
}

output "lambda_aggregate_errors_alarm_arn" {
  description = "ARN of the aggregate Lambda errors alarm, null when lambda_aggregate_alarm is false."
  value       = one(aws_cloudwatch_metric_alarm.lambda_aggregate_errors[*].arn)
}

output "lambda_aggregate_throttles_alarm_arn" {
  description = "ARN of the aggregate Lambda throttles alarm, null when lambda_aggregate_alarm is false."
  value       = one(aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[*].arn)
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
