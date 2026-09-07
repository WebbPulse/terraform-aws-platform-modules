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
    [for a in aws_cloudwatch_metric_alarm.api_5xx : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.api_integration_latency : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_throttles : a.alarm_name],
  ))
}

output "alarm_arns" {
  description = "Every alarm ARN this module created, sorted."
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.api_5xx : a.arn],
    [for a in aws_cloudwatch_metric_alarm.api_integration_latency : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dynamodb_throttles : a.arn],
  ))
}

output "lambda_alarm_names" {
  description = "Names of the two Lambda alarms, empty when lambda_function_name is null."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.alarm_name],
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
