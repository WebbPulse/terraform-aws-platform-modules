output "resource_policy_name" {
  description = "Name of the CloudWatch Logs resource policy that lets X-Ray put span events."
  value       = aws_cloudwatch_log_resource_policy.spans.policy_name
}

output "resource_policy_document" {
  description = "The resource policy JSON the module wrote."
  value       = data.aws_iam_policy_document.spans.json
}

output "spans_log_group_name" {
  description = "Reserved log group spans land in, whether or not this module adopted it."
  value       = var.spans_log_group_name
}

output "spans_log_group_arn" {
  description = "ARN of the adopted spans log group, null when adopt_spans_log_group is false."
  value       = var.adopt_spans_log_group ? aws_cloudwatch_log_group.spans[var.spans_log_group_name].arn : null
}

output "trace_segment_destination" {
  description = "Destination X-Ray sends trace segments to, which is CloudWatchLogs once this module has applied."
  value       = aws_xray_trace_segment_destination.this.destination
}

output "indexing_rule_name" {
  description = "Name of the managed X-Ray indexing rule, null when create_indexing_rule is false."
  value       = var.create_indexing_rule ? aws_xray_indexing_rule.default[0].name : null
}

output "application_signals_log_group_arn" {
  description = "ARN of the adopted Application Signals log group, null when adopt_application_signals_log_group is false."
  value       = var.adopt_application_signals_log_group ? aws_cloudwatch_log_group.application_signals[var.application_signals_log_group_name].arn : null
}

output "otel_environment_variables" {
  description = "Environment variables that apply span_sample_ratio, ready to merge into the lambda-function module's otel_environment_variables. Empty when span_sample_ratio is null."
  value       = local.otel_environment_variables
}
