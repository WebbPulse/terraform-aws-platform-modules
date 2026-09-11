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

  # Identity JWT enforcement, decided here for the same reason the line above is decided here.
  #
  # `require_identity_jwt = true` on a route is one statement of intent with two implementations,
  # because an HTTP API route takes exactly one authorizer and in staging that one is already spoken
  # for:
  #
  #   PRODUCTION  identity_jwt is set and nothing fronts the API, so the route becomes
  #               authorization_type JWT against the aws_apigatewayv2_authorizer this module
  #               creates. API Gateway verifies the RS256 signature against the JWKS the issuer
  #               publishes and hands the claims to the integration at
  #               requestContext.authorizer.jwt.claims as a map of strings.
  #
  #   STAGING     every route already carries the access gate's REQUEST authorizer, and that one
  #               slot cannot hold a second authorizer. The route's authorization stays exactly what
  #               it is today, CUSTOM against var.authorizer_id, and enforcement moves into the
  #               gate's own Lambda: it is handed this list of route keys as
  #               IDENTITY_JWT_ROUTE_KEYS and requires a valid token on a request whose
  #               requestContext.routeKey is in it.
  #
  #               The route key is the signal rather than a second authorizer because the payload
  #               2.0 authorizer event does not name the authorizer that invoked the function:
  #               routeArn is a route ARN and there is no authorizer id anywhere in the event. Two
  #               authorizer resources over one Lambda are legal and would be indistinguishable from
  #               inside it. routeKey is in the event, is exactly the string this module keys
  #               var.routes by, and is the same string on both sides by construction.
  #
  # identity_jwt_route_keys is therefore an output rather than something this module can apply on
  # its own in staging, and it is the whole of the staging wiring: one output into one gate input.
  #
  # Neither input set means require_identity_jwt is inert, which is what keeps this additive.
  identity_jwt_enabled = var.identity_jwt != null

  # Whether this module creates the authorizer or attaches one that already exists. The identity
  # module makes an identical one and polls the discovery document before creating it, which is a
  # stronger ordering guarantee than anything available here, so a consumer using that module should
  # pass its authorizer_id rather than have a second authorizer validating the same issuer.
  identity_jwt_create = local.identity_jwt_enabled && var.identity_jwt.authorizer_id == null

  identity_jwt_name = local.identity_jwt_create ? coalesce(var.identity_jwt.name, "${var.name}-identity-jwt") : null

  identity_jwt_audiences = local.identity_jwt_create ? coalesce(var.identity_jwt.audiences, [var.identity_jwt.audience]) : null

  identity_jwt_identity_sources = local.identity_jwt_create ? coalesce(var.identity_jwt.identity_sources, ["$request.header.Authorization"]) : null

  # The route keys that asked for a token, sorted so the output, the gate's environment variable and
  # any error message are stable. A plan that reordered a map would otherwise redeploy the gate's
  # Lambda for no change.
  identity_jwt_route_keys = sort([
    for k, r in var.routes : k if coalesce(r.require_identity_jwt, false)
  ])

  # Every route the module creates, $default included, as one map keyed by route key. The explicit
  # routes come from var.routes; $default is synthesised from var.default_integration so that a
  # consumer cannot forget it and cannot give it different authorization by accident.
  #
  # $default never requires an identity token. It is the catch-all for everything no explicit route
  # claims, which during a strangler migration is the whole monolith, and marking it would turn on
  # enforcement for every path nobody has listed yet. A consumer that wants a prefix enforced lists
  # that prefix.
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

  # Resolved per route: an explicit override wins, otherwise the module-wide choice.
  #
  # An authorizer id only belongs on a route whose effective authorization_type is CUSTOM or JWT.
  # NONE and AWS_IAM take no authorizer: API Gateway accepts the create with one attached, ignores
  # it, and stores nothing, so state reads back authorizer_id = "" while the configuration still
  # says the gate's id. That is a perpetual in-place update on every later plan, which is how this
  # surfaced on Portfolio staging's two public .well-known routes. Resolving to null here keeps the
  # configuration and the API's own view of the route in agreement.
  #
  # require_identity_jwt is folded in below the explicit override, so an authorization_type written
  # on the same entry still wins and the route's own authorizer_id still wins over either default.
  # Only the production half lands on the route resource. In staging a marked route is
  # indistinguishable in Terraform from an unmarked one, which is the point: switching the gate on
  # or off never rewrites a route's authorization.
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
        # Deliberately not the identity JWT authorizer's id, even for a route that resolves to JWT
        # through it. This local feeds the open routes as well as the protected ones, and a local is
        # a single node in Terraform's graph however it is filtered downstream, so naming the
        # authorizer here puts every route on this API behind it and rebuilds the cycle the split in
        # identity_jwt.tf exists to break. The protected route resource substitutes the id itself,
        # which is the only place it is needed and the only place it can be read.
        r.authorizer_id != null ? r.authorizer_id : var.authorizer_id
      ) : null
      authorization_scopes = r.authorization_scopes
      require_identity_jwt = coalesce(r.require_identity_jwt, false)
    }
  }

  # The two halves of resolved_routes, split by which side of the JWT authorizer a route has to be
  # created on. See modules/http-api/identity_jwt.tf for why that split has to exist at all.
  #
  # A route is only protected when this module is the thing doing the protecting. In staging, where
  # identity_jwt is null and the gate's Lambda enforces the token, every route stays in
  # resolved_open_routes at the address it has always had, so switching the gate on or off never
  # moves a route between resources.
  identity_jwt_protected_routes = {
    for k, r in local.resolved_routes : k => r
    if r.require_identity_jwt && local.identity_jwt_enabled
  }

  resolved_open_routes = {
    for k, r in local.resolved_routes : k => r
    if !(r.require_identity_jwt && local.identity_jwt_enabled)
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

# A route naming an unknown integration, and a default_integration that names nothing, are both
# caught by the precondition on aws_apigatewayv2_route.this in api.tf. That precondition fires
# before the route's target expression is evaluated, so it reports the offending route key by name
# rather than letting a raw "Invalid index" escape, and it stops the plan rather than only warning.
#
# The checks below cover the two problems no precondition catches, because they are about
# resources that would otherwise plan perfectly cleanly while doing nothing.
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
