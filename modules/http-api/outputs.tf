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

output "integration_id" {
  description = "Id of the Lambda proxy integration."
  value       = aws_apigatewayv2_integration.lambda.id
}

output "route_ids" {
  description = "Route ids keyed by route key."
  value       = { for k, r in aws_apigatewayv2_route.this : k => r.id }
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
