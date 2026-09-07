locals {
  custom_domain = var.domain_name != null
  dns_record    = local.custom_domain && var.zone_id != null

  access_log_group_name = coalesce(var.access_log_group_name, "/aws/apigateway/${var.name}")

  # An unset tags argument and an empty map plan identically on provider 5.x, but passing null
  # keeps the configuration byte-for-byte what an adopting consumer had before the move.
  tags             = length(var.tags) > 0 ? var.tags : null
  domain_name_tags = length(merge(var.tags, var.domain_name_tags)) > 0 ? merge(var.tags, var.domain_name_tags) : null

  # Authorization is decided here, once, for every route the module creates. The Portfolio
  # inventory found a route added by hand without an authorization_type, which silently defaults
  # to NONE and is a hole straight through the staging access gate. Because $default is built from
  # default_integration rather than listed in var.routes, there is no route on this API that can be
  # created without going through this local.
  authorization_type = var.authorizer_id == null ? "NONE" : "CUSTOM"

  # Every route the module creates, $default included, as one map keyed by route key. The explicit
  # routes come from var.routes; $default is synthesised from var.default_integration so that a
  # consumer cannot forget it and cannot give it different authorization by accident.
  default_route = var.default_integration == null ? {} : {
    "$default" = {
      integration          = var.default_integration
      authorization_type   = null
      authorizer_id        = null
      authorization_scopes = null
    }
  }

  all_routes = merge(local.default_route, var.routes)

  # Resolved per route: an explicit override wins, otherwise the module-wide choice.
  resolved_routes = {
    for k, r in local.all_routes : k => {
      integration          = r.integration
      authorization_type   = coalesce(r.authorization_type, local.authorization_type)
      authorizer_id        = r.authorizer_id != null ? r.authorizer_id : var.authorizer_id
      authorization_scopes = r.authorization_scopes
    }
  }

  # Resolved per integration: entry-level setting, otherwise the module-wide default. The statement
  # id of the default integration is var.lambda_permission_statement_id verbatim, so an adopting
  # consumer's existing permission keeps the id it already has in state and is not replaced.
  resolved_integrations = {
    for k, i in var.integrations : k => {
      lambda_function_name   = i.lambda_function_name
      lambda_invoke_arn      = i.lambda_invoke_arn
      payload_format_version = coalesce(i.payload_format_version, var.payload_format_version)
      timeout_milliseconds   = i.timeout_milliseconds
      # The statement id has to be unique per function, so a second backend cannot reuse the bare
      # one. It also has to stay byte-identical for a consumer adopting from 1.x, where there was
      # one permission carrying var.lambda_permission_statement_id exactly. Both hold if the bare
      # id goes to the single integration of a one-backend API, and to the default_integration
      # otherwise, with every other backend suffixed by its key.
      statement_id = coalesce(
        i.lambda_permission_statement_id,
        length(var.integrations) == 1 || k == var.default_integration ? var.lambda_permission_statement_id : "${var.lambda_permission_statement_id}-${k}",
      )
    }
  }

  # Cross-variable checks. These are locals rather than variable validations so that the error
  # message can name the offending key, and so that a consumer sees every problem at once.
  unknown_route_integrations = [
    for k, r in local.all_routes : "${k} -> ${r.integration}"
    if !contains(keys(var.integrations), r.integration)
  ]

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

# The checks run at plan time and name what is wrong, instead of surfacing as a for_each key error
# or, worse, as a route that answers nothing.
check "routes_target_known_integrations" {
  assert {
    condition     = length(local.unknown_route_integrations) == 0
    error_message = "These routes name an integration that is not in var.integrations: ${join(", ", local.unknown_route_integrations)}."
  }
}

check "default_integration_exists" {
  assert {
    condition     = var.default_integration == null || contains(keys(var.integrations), var.default_integration)
    error_message = "default_integration is \"${coalesce(var.default_integration, "null")}\", which is not a key in var.integrations. Set it to the integration that should serve $default, or to null to create no $default route."
  }
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
