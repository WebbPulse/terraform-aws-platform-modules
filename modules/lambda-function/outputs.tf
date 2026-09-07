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
