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

  depends_on = [
    aws_apigatewayv2_route.this,
    aws_apigatewayv2_stage.default,
    var.identity_jwt_depends_on,
  ]

  lifecycle {
    precondition {
      condition     = length(local.identity_jwt_route_keys) > 0
      error_message = "identity_jwt is set but no route sets require_identity_jwt = true, so the authorizer would be created and attached to nothing. Mark the routes that need a token, or leave identity_jwt null."
    }
  }
}

resource "aws_apigatewayv2_route" "identity_jwt" {
  for_each = local.identity_jwt_protected_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.value.integration].id}"
  authorization_type = each.value.authorization_type

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
