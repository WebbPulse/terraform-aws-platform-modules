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
  description = "Id of the integration behind $default, null when default_integration is null or names no integration. The 1.x integration_id under its new name."
  value       = try(aws_apigatewayv2_integration.this[var.default_integration].id, null)
}

output "route_ids" {
  description = "Route ids keyed by route key, $default included. Both route resources are merged here, so a route's presence in this map does not change when it gains or loses require_identity_jwt."
  value = merge(
    { for k, r in aws_apigatewayv2_route.this : k => r.id },
    { for k, r in aws_apigatewayv2_route.identity_jwt : k => r.id },
  )
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

output "identity_jwt_authorizer_id" {
  description = "Id of the JWT authorizer the marked routes are behind, whether this module created it or identity_jwt.authorizer_id supplied it. Null when identity_jwt is not set. Already attached to every route that sets require_identity_jwt, so a consumer needs this only to attach it to a route it creates outside the module."
  value       = local.identity_jwt_enabled ? coalesce(var.identity_jwt.authorizer_id, one(aws_apigatewayv2_authorizer.identity_jwt[*].id)) : null
}

output "identity_jwt_authorizer_name" {
  description = "Name of the JWT authorizer, null when it was not created."
  value       = one(aws_apigatewayv2_authorizer.identity_jwt[*].name)
}

output "identity_jwt_route_keys" {
  description = "Every route key that sets require_identity_jwt, sorted. This is the staging wiring in one value: pass it to staging-access-gate's identity_jwt_route_keys and the gate's Lambda requires a valid access token on exactly these routes, because the route key in its event is the same string this module keys var.routes by. Empty when no route is marked."
  value       = local.identity_jwt_route_keys
}

output "route_identity_jwt_required" {
  description = "Whether each route key requires an identity token, $default included. The audit view: read it in a plan to see which paths are open and which are closed, without reading the routes map back."
  value       = { for k, r in local.resolved_routes : k => r.require_identity_jwt }
}
