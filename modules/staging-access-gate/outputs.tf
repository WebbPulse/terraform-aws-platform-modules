output "key_group_id" {
  description = "CloudFront key group to set as trusted_key_groups on every behavior that must require a session."
  value       = aws_cloudfront_key_group.signing.id
}

output "viewer_request_function_arn" {
  description = "CloudFront Function to associate as viewer-request on the default behavior, on the login behavior, and on any unsigned fallback behavior such as /index.html."
  value       = aws_cloudfront_function.gate.arn
}

output "login_origin_domain_name" {
  description = "Origin domain name for the login Lambda function URL."
  value       = local.login_origin_domain_name
}

output "login_origin_access_control_id" {
  description = "Origin access control id to set on the login origin."
  value       = aws_cloudfront_origin_access_control.login.id
}

output "auth_path_pattern" {
  description = "Path pattern for the ordered cache behavior that routes to the login origin."
  value       = local.auth_path_pattern
}

output "api_path_pattern" {
  description = "Path pattern for the ordered cache behavior that routes to the API origin."
  value       = local.api_path_pattern
}

output "origin_verify_header_name" {
  description = "Custom header name to add to the API origin."
  value       = var.origin_verify_header_name
}

output "origin_verify_header_value" {
  description = "Custom header value to add to the API origin."
  value       = random_password.origin_verify.result
  sensitive   = true
}

output "origin_verify_ssm_parameter_name" {
  description = "SSM parameter holding the origin verification header value, for pipelines that need to call the API host directly."
  value       = aws_ssm_parameter.origin_verify.name
}

output "origin_verify_ssm_parameter_arn" {
  description = "ARN of the SSM parameter holding the origin verification header value."
  value       = aws_ssm_parameter.origin_verify.arn
}

output "http_api_authorizer_id" {
  description = "Id of the HTTP API REQUEST authorizer, null when http_api_id was not given."
  value       = one(aws_apigatewayv2_authorizer.origin_verify[*].id)
}

output "user_pool_id" {
  description = "Cognito user pool id."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_client_id" {
  description = "Cognito app client id used by the login Lambda."
  value       = aws_cognito_user_pool_client.login.id
}

output "hosted_ui_domain" {
  description = "Base URL of the Cognito hosted UI."
  value       = local.hosted_ui_domain
}

output "login_function_name" {
  description = "Name of the login Lambda function."
  value       = aws_lambda_function.login.function_name
}

output "cache_policy_id_caching_disabled" {
  description = "AWS managed CachingDisabled cache policy id, for the login and API behaviors."
  value       = local.cache_policy_caching_disabled
}

output "origin_request_policy_id_all_viewer_except_host_header" {
  description = "AWS managed AllViewerExceptHostHeader origin request policy id, for the login and API behaviors."
  value       = local.origin_request_policy_all_viewer_except_host
}

output "identity_jwt_enforced" {
  description = "Whether the authorizer additionally requires an identity access token. True only when identity_jwt is set and identity_jwt_route_keys names at least one route; either half alone enforces nothing."
  value       = local.identity_jwt_enabled
}

output "identity_jwt_route_keys" {
  description = "The route keys the authorizer requires an identity access token on, sorted, echoed back so a consumer can assert the set in a plan. Empty when nothing is enforced."
  value       = local.identity_jwt_enabled ? local.identity_jwt_route_keys : []
}
