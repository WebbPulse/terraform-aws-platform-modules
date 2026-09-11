locals {
  custom_domain = var.domain_name != null
  dns_record    = local.custom_domain && var.zone_id != null

  access_log_group_name = coalesce(var.access_log_group_name, "/aws/apigateway/${var.name}")

  tags             = length(var.tags) > 0 ? var.tags : null
  domain_name_tags = length(merge(var.tags, var.domain_name_tags)) > 0 ? merge(var.tags, var.domain_name_tags) : null

  authorization_type = var.authorizer_id == null ? "NONE" : "CUSTOM"

  identity_jwt_enabled = var.identity_jwt != null

  identity_jwt_create = local.identity_jwt_enabled && var.identity_jwt.authorizer_id == null

  identity_jwt_name = local.identity_jwt_create ? coalesce(var.identity_jwt.name, "${var.name}-identity-jwt") : null

  identity_jwt_audiences = local.identity_jwt_create ? coalesce(var.identity_jwt.audiences, [var.identity_jwt.audience]) : null

  identity_jwt_identity_sources = local.identity_jwt_create ? coalesce(var.identity_jwt.identity_sources, ["$request.header.Authorization"]) : null

  identity_jwt_route_keys = sort([
    for k, r in var.routes : k if coalesce(r.require_identity_jwt, false)
  ])

  default_route = var.default_integration == null ? {} : {
    "$default" = {
      integration          = var.default_integration
      authorization_type   = null
      authorizer_id        = null
      authorization_scopes = null
      require_identity_jwt = false
    }
  }

  all_routes = merge(local.default_route, var.routes)

  route_identity_type = {
    for k, r in local.all_routes : k =>
    coalesce(r.require_identity_jwt, false) && local.identity_jwt_enabled ? "JWT" : null
  }

  resolved_routes = {
    for k, r in local.all_routes : k => {
      integration = r.integration
      authorization_type = coalesce(
        r.authorization_type,
        local.route_identity_type[k],
        local.authorization_type,
      )
      authorizer_id = contains(["CUSTOM", "JWT"], coalesce(r.authorization_type, local.route_identity_type[k], local.authorization_type)) ? (
        r.authorizer_id != null ? r.authorizer_id : var.authorizer_id
      ) : null
      authorization_scopes = r.authorization_scopes
      require_identity_jwt = coalesce(r.require_identity_jwt, false)
    }
  }

  identity_jwt_protected_routes = {
    for k, r in local.resolved_routes : k => r
    if r.require_identity_jwt && local.identity_jwt_enabled
  }

  resolved_open_routes = {
    for k, r in local.resolved_routes : k => r
    if !(r.require_identity_jwt && local.identity_jwt_enabled)
  }

  resolved_integrations = {
    for k, i in var.integrations : k => {
      lambda_function_name   = i.lambda_function_name
      lambda_invoke_arn      = i.lambda_invoke_arn
      payload_format_version = coalesce(i.payload_format_version, var.payload_format_version)
      timeout_milliseconds   = i.timeout_milliseconds
      statement_id = coalesce(
        i.lambda_permission_statement_id,
        length(var.integrations) == 1 || k == var.default_integration ? var.lambda_permission_statement_id : "${var.lambda_permission_statement_id}-${k}",
      )
    }
  }

  unknown_route_settings = [
    for k, _ in var.route_settings : k
    if !contains(keys(local.all_routes), k)
  ]

  unused_integrations = [
    for k, _ in var.integrations : k
    if !contains([for _, r in local.all_routes : r.integration], k)
  ]

  api_url = local.custom_domain ? "https://${var.domain_name}" : aws_apigatewayv2_api.this.api_endpoint
}

check "route_settings_name_real_routes" {
  assert {
    condition     = length(local.unknown_route_settings) == 0
    error_message = "These route_settings keys name no route on this API, so the settings would apply to nothing: ${join(", ", local.unknown_route_settings)}."
  }
}

check "every_integration_is_routed" {
  assert {
    condition     = length(local.unused_integrations) == 0
    error_message = "These integrations have no route and no $default, so nothing can reach them: ${join(", ", local.unused_integrations)}. Give each one a routes entry or make it the default_integration."
  }
}
