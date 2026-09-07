output "api_id" {
  description = "Id of the HTTP API. Hand it to staging-access-gate as http_api_id."
  value       = aws_apigatewayv2_api.this.id
}

output "api_arn" {
  description = "ARN of the HTTP API."
  value       = aws_apigatewayv2_api.this.arn
}

output "execution_arn" {
  description = "Execution ARN of the API, the prefix of every route's invoke ARN."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "api_endpoint" {
  description = "Default execute-api endpoint, https://<api-id>.execute-api.<region>.amazonaws.com. Still reported when disable_execute_api_endpoint is true, but then it answers 403."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "stage_id" {
  description = "Id of the $default stage."
  value       = aws_apigatewayv2_stage.default.id
}

output "stage_arn" {
  description = "ARN of the $default stage."
  value       = aws_apigatewayv2_stage.default.arn
}

output "integration_ids" {
  description = "Integration ids keyed by integrations key."
  value       = { for k, i in aws_apigatewayv2_integration.this : k => i.id }
}

output "default_integration_id" {
  description = "Id of the integration behind $default, null when default_integration is null. The 1.x integration_id under its new name."
  value       = var.default_integration == null ? null : aws_apigatewayv2_integration.this[var.default_integration].id
}

output "route_ids" {
  description = "Route ids keyed by route key, $default included."
  value       = { for k, r in aws_apigatewayv2_route.this : k => r.id }
}

output "route_integrations" {
  description = "Which integration serves each route key, so a consumer can assert the strangler split in a test or print it in a plan."
  value       = { for k, r in local.resolved_routes : k => r.integration }
}

output "lambda_permission_statement_ids" {
  description = "statement_id of each invoke permission, keyed by integrations key. Useful when adopting: the default_integration entry must match the statement id already in state."
  value       = { for k, p in aws_lambda_permission.this : k => p.statement_id }
}

output "access_log_group_name" {
  description = "Name of the access log group."
  value       = aws_cloudwatch_log_group.access.name
}

output "access_log_group_arn" {
  description = "ARN of the access log group."
  value       = aws_cloudwatch_log_group.access.arn
}

output "domain_name" {
  description = "The custom hostname, null when none was configured."
  value       = var.domain_name
}

output "custom_domain_target_domain_name" {
  description = "Regional hostname API Gateway serves the custom domain from; the alias target for a DNS record. Null without a custom domain."
  value       = one(aws_apigatewayv2_domain_name.this[*].domain_name_configuration[0].target_domain_name)
}

output "custom_domain_hosted_zone_id" {
  description = "Route 53 hosted zone id of that regional hostname, for the alias record. Null without a custom domain."
  value       = one(aws_apigatewayv2_domain_name.this[*].domain_name_configuration[0].hosted_zone_id)
}

output "api_url" {
  description = "Origin the frontend and pipelines should use: https://<domain_name> with a custom domain, the execute-api endpoint otherwise."
  value       = local.api_url
}
