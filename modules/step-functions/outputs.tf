output "arn" {
  description = "ARN of the state machine. This is the resource a states:StartExecution policy names, and the value an EventBridge target or another state machine points at."
  value       = aws_sfn_state_machine.this.arn
}

output "name" {
  description = "Name of the state machine, for a CloudWatch alarm dimension or a StartExecution call that takes the name rather than the ARN."
  value       = aws_sfn_state_machine.this.name
}

output "state_machine_version_arn" {
  description = "ARN of the version published for the current definition, empty unless publish is on. An alias points at this rather than at the state machine."
  value       = aws_sfn_state_machine.this.state_machine_version_arn
}

output "role_arn" {
  description = "ARN of the execution role, for a policy naming the role as a principal, for example an iam:PassRole condition or a KMS key policy."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the execution role, for an aws_iam_role_policy_attachment outside this module."
  value       = aws_iam_role.this.name
}

output "role_id" {
  description = "Id of the execution role, which is what an aws_iam_role_policy resource takes as its role argument. Grants beyond policy_statements attach here."
  value       = aws_iam_role.this.id
}

output "log_group_name" {
  description = "Name of the state machine's CloudWatch log group, for a metric filter or a Logs Insights query."
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "ARN of the state machine's CloudWatch log group. The logging_configuration's destination is this value with :* appended, which is the form vended log delivery requires."
  value       = aws_cloudwatch_log_group.this.arn
}

output "caller_policy_json" {
  description = "An IAM policy document for a caller that drives this state machine: states:StartExecution on the machine, DescribeExecution and StopExecution on its executions, and SendTaskSuccess, SendTaskFailure and SendTaskHeartbeat for an activity worker holding a task token. Attach it with policy = module.<this>.caller_policy_json on an aws_iam_role_policy. The three task-token actions are on Resource \"*\" because they authorize against the token, not against an ARN."
  value       = local.caller_policy_json
}

output "xray_write_policy_attached" {
  description = "Whether the module attached its inline X-Ray write policy to the execution role. False when tracing_enabled is off or attach_xray_write_policy is off, in which case the caller owns that grant."
  value       = local.attach_xray_write_policy
}
