output "function_name" {
  description = "Name of the function, for a Lambda invoke permission, an alarm dimension or a deployment pipeline's UpdateFunctionCode call."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "ARN of the function, without a version qualifier. Use it as the resource of a lambda:UpdateFunctionCode policy statement."
  value       = aws_lambda_function.this.arn
}

output "invoke_arn" {
  description = "ARN to give an API Gateway AWS_PROXY integration as integration_uri, for example the http-api module's lambda_invoke_arn."
  value       = aws_lambda_function.this.invoke_arn
}

output "qualified_arn" {
  description = "ARN of the most recently published version, empty unless publish is on."
  value       = aws_lambda_function.this.qualified_arn
}

output "qualified_invoke_arn" {
  description = "Invoke ARN of the most recently published version, empty unless publish is on."
  value       = aws_lambda_function.this.qualified_invoke_arn
}

output "version" {
  description = "Latest published version of the function, $LATEST unless publish is on."
  value       = aws_lambda_function.this.version
}

output "role_name" {
  description = "Name of the execution role, for aws_iam_role_policy_attachment outside this module."
  value       = aws_iam_role.this.name
}

output "role_id" {
  description = "Id of the execution role, which is what an aws_iam_role_policy resource takes as its role argument. The application's own permission policies attach here."
  value       = aws_iam_role.this.id
}

output "role_arn" {
  description = "ARN of the execution role, for a policy that names the role as a principal or a trust relationship elsewhere."
  value       = aws_iam_role.this.arn
}

output "role_unique_id" {
  description = "Stable unique id of the execution role, usable in an aws:userId condition."
  value       = aws_iam_role.this.unique_id
}

output "log_group_name" {
  description = "Name of the function's CloudWatch log group."
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "ARN of the function's CloudWatch log group. A runtime policy granting logs:CreateLogStream and logs:PutLogEvents appends :* to this value."
  value       = aws_cloudwatch_log_group.this.arn
}

output "package_type" {
  description = "How the function is packaged, Zip or Image. Echoes the input, so a caller composing on top of this module does not have to repeat the decision."
  value       = aws_lambda_function.this.package_type
}

output "image_uri" {
  description = "Container image the function currently runs, empty for a Zip function. This is the seed value Terraform set: image_uri is under ignore_changes, so once CI has deployed an image the value here is the one in state rather than the one running."
  value       = aws_lambda_function.this.image_uri
}

output "xray_write_policy_attached" {
  description = "Whether the module attached its inline X-Ray write policy to the execution role. False when tracing_mode is not Active or attach_xray_write_policy is off, in which case the application owns that grant."
  value       = local.attach_xray_write_policy
}

output "sqs_event_source_mapping_uuids" {
  description = "UUID of each SQS event source mapping, keyed as sqs_event_sources was. The UUID is what an UpdateEventSourceMapping call or a console deep link takes, and it is the only stable handle on a mapping, which has no name."
  value       = { for key, mapping in aws_lambda_event_source_mapping.sqs : key => mapping.uuid }
}

output "sqs_event_source_policy_json" {
  description = "Queue read policy document per sqs_event_sources entry, granting sqs:ReceiveMessage, sqs:DeleteMessage and sqs:GetQueueAttributes on that queue plus kms:Decrypt on its key when one was given. Already attached to the execution role unless attach_role_policies is off, in which case a consumer attaches these itself."
  value       = local.sqs_event_source_policy_json
}

output "events_path" {
  description = "Path the Web Adapter posts a non-HTTP invocation to, which is also the path the application mounts its event route on. Empty when no SQS event source is wired, because the pass through variables are only emitted alongside a mapping."
  value       = length(var.sqs_event_sources) > 0 ? var.events_path : null
}
