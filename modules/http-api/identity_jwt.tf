# ---------------------------------------------------------------------------
# The identity JWT authorizer, production's half of require_identity_jwt.
#
# API Gateway verifies the RS256 signature itself, against the JWKS the issuer publishes, and
# checks iss, aud, exp and nbf. Nothing of ours runs on the hot path and there is no per request
# cost beyond the gateway's own. That is why production uses the native authorizer and staging only
# falls back to the gate's Lambda: staging has no free authorizer slot, not because the Lambda is
# preferable.
#
# ORDERING, WHICH IS THE ONE THING THAT MAKES THIS RESOURCE AWKWARD.
#
# CreateAuthorizer on an HTTP API validates the issuer synchronously: API Gateway fetches
# <issuer>/.well-known/openid-configuration during the create call and rejects it with
#
#     BadRequestException: ... Issuer must have a valid discovery endpoint ended with
#     '/.well-known/openid-configuration'
#
# when it does not get a document back. So two things must already be true when this is created:
#
#  1. the two .well-known routes exist on this API and answer ANONYMOUSLY, because API Gateway's
#     own validator fetches them from outside with no credentials of ours; and
#  2. the identity function behind them is deployed and serving.
#
# WHY THE PROTECTED ROUTES ARE A SEPARATE RESOURCE.
#
# The first requirement cannot be expressed with one route resource. A route that names this
# authorizer must be created after it, and the .well-known routes must be created before it, so a
# single for_each over every route would have to be both, and Terraform refuses the graph:
#
#     Cycle: aws_apigatewayv2_route.this -> local.resolved_routes -> local.route_identity_authorizer
#            -> aws_apigatewayv2_authorizer.identity_jwt -> aws_apigatewayv2_route.this
#
# So the routes are split by what they need rather than by what they are. Every route that does not
# name this authorizer stays at aws_apigatewayv2_route.this, exactly where it has always been, and
# the authorizer waits on all of them. Every route that does name it moves to
# aws_apigatewayv2_route.identity_jwt, which waits on the authorizer. Both resources are fed from
# the same local.resolved_routes, so authorization is still decided in one place for every route on
# the API and neither resource can be created without going through it.
#
# The split is by address and not by behaviour, but an address is not free: a route that gains
# require_identity_jwt moves between the two resources, which destroys and recreates that route.
# For a route being switched from open to token-required that is the correct blast radius and it is
# seconds of 404 on one path, but it is a replacement rather than an in-place update and a plan
# says so. Marking the routes in the same apply that first sets identity_jwt keeps it to one move.
#
# The second requirement Terraform cannot express at all: depends_on orders API calls and not their
# effects, and three lags sit between "CreateRoute returned 201" and "an outside request gets a
# document back". An auto_deploy stage deploys asynchronously, UpdateFunctionConfiguration returns
# while LastUpdateStatus is still InProgress, and a container image function under the Lambda Web
# Adapter takes seconds to cold start. identity_jwt_depends_on is where a consumer names the
# function, and on a first apply it is worth applying the function and the routes in an earlier run.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "identity_jwt" {
  count = local.identity_jwt_create ? 1 : 0

  api_id           = aws_apigatewayv2_api.this.id
  name             = local.identity_jwt_name
  authorizer_type  = "JWT"
  identity_sources = local.identity_jwt_identity_sources

  jwt_configuration {
    issuer   = var.identity_jwt.issuer
    audience = local.identity_jwt_audiences
  }

  # The routes serving the discovery document and the JWKS have to exist before API Gateway fetches
  # them, and this is what says so. It is every anonymous route rather than the two .well-known ones
  # by name, because naming them would make the module care which keys a consumer chose for them.
  # The stage is in the list because a route is only reachable once the stage has deployed it.
  depends_on = [
    aws_apigatewayv2_route.this,
    aws_apigatewayv2_stage.default,
    var.identity_jwt_depends_on,
  ]

  # A route cannot require a token that no authorizer is configured to check. Both halves resolve
  # from variables alone, so this is caught at plan time rather than by a request that should have
  # been refused and was not.
  lifecycle {
    precondition {
      condition     = length(local.identity_jwt_route_keys) > 0
      error_message = "identity_jwt is set but no route sets require_identity_jwt = true, so the authorizer would be created and attached to nothing. Mark the routes that need a token, or leave identity_jwt null."
    }
  }
}

# The routes that name the authorizer, created after it. Everything about an entry here is decided
# by the same local.resolved_routes the open routes come from; the only difference is which side of
# the authorizer it lands on in the graph. See the ordering note above for why the split exists.
resource "aws_apigatewayv2_route" "identity_jwt" {
  for_each = local.identity_jwt_protected_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.value.integration].id}"
  authorization_type = each.value.authorization_type

  # The one attribute that is not taken from local.resolved_routes. See the note on authorizer_id
  # there: the shared local cannot name this authorizer without putting every route on the API
  # behind it in the graph. A route-level authorizer_id still wins, so a consumer can point one
  # protected route at an authorizer of its own.
  authorizer_id = coalesce(
    each.value.authorizer_id,
    var.identity_jwt.authorizer_id,
    one(aws_apigatewayv2_authorizer.identity_jwt[*].id),
  )

  authorization_scopes = each.value.authorization_scopes

  lifecycle {
    precondition {
      condition     = contains(keys(var.integrations), each.value.integration)
      error_message = "Route \"${each.key}\" names integration \"${each.value.integration}\", which is not a key in var.integrations (${join(", ", keys(var.integrations))})."
    }
  }
}
