variables {
  name = "example-test-api"

  integrations = {
    legacy = {
      lambda_function_name = "example-test-legacy"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-test-legacy/invocations"
    }
    identity = {
      lambda_function_name = "example-test-identity"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-test-identity/invocations"
    }
  }

  default_integration = "legacy"

  routes = {
    "GET /.well-known/openid-configuration" = { integration = "identity", authorization_type = "NONE" }
    "GET /.well-known/jwks.json"            = { integration = "identity", authorization_type = "NONE" }

    "POST /api/auth/login"    = { integration = "identity" }
    "POST /api/auth/refresh"  = { integration = "identity" }
    "POST /api/auth/register" = { integration = "identity" }

    "GET /api/auth/me"      = { integration = "identity", require_identity_jwt = true }
    "POST /api/auth/logout" = { integration = "identity", require_identity_jwt = true }
    "ANY /api/v1/{proxy+}"  = { integration = "legacy", require_identity_jwt = true }
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "production_marked_routes_are_jwt_and_unmarked_routes_are_not" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "https://api.example.com/api/auth"
      audience = "example-production-api"
    }
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt) == 1
    error_message = "identity_jwt was set but no JWT authorizer was planned."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].authorizer_type == "JWT"
    error_message = "The identity authorizer must be a native JWT authorizer, not a REQUEST one."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].jwt_configuration[0].issuer == "https://api.example.com/api/auth"
    error_message = "The authorizer's issuer is not the one that was configured; a mismatch denies every request with nothing in any log to say why."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].jwt_configuration[0].audience == toset(["example-production-api"])
    error_message = "The authorizer's audience list is not exactly [audience]."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].identity_sources == toset(["$request.header.Authorization"])
    error_message = "The authorizer must read the token from the Authorization header by default."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].name == "example-test-api-identity-jwt"
    error_message = "The authorizer name is not the default <var.name>-identity-jwt."
  }

  assert {
    condition     = length(aws_apigatewayv2_route.identity_jwt) == 3
    error_message = "Expected exactly the three routes that set require_identity_jwt on the protected route resource."
  }

  assert {
    condition     = alltrue([for _, r in aws_apigatewayv2_route.identity_jwt : r.authorization_type == "JWT"])
    error_message = "A route that requires an identity token did not resolve to authorization_type JWT."
  }

  assert {
    condition     = output.route_identity_jwt_required["GET /api/auth/me"]
    error_message = "GET /api/auth/me does not require an identity token."
  }

  assert {
    condition     = output.route_identity_jwt_required["ANY /api/v1/{proxy+}"]
    error_message = "The domain proxy route does not require an identity token."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /.well-known/openid-configuration"].authorization_type == "NONE"
    error_message = "The discovery document route is not anonymous. API Gateway fetches it during CreateAuthorizer with no credentials, so an authorizer on it fails the apply."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /.well-known/jwks.json"].authorization_type == "NONE"
    error_message = "The JWKS route is not anonymous."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["POST /api/auth/login"].authorization_type == "NONE"
    error_message = "Login is not anonymous, so nobody could ever obtain a first token."
  }

  assert {
    condition     = !output.route_identity_jwt_required["POST /api/auth/refresh"]
    error_message = "Refresh must not require an access token: it is the flow for a caller whose access token has expired."
  }

  assert {
    condition     = !output.route_identity_jwt_required["$default"]
    error_message = "$default must never require an identity token: it is the catch-all for every path no route claims."
  }

  assert {
    condition     = output.identity_jwt_route_keys == tolist(["ANY /api/v1/{proxy+}", "GET /api/auth/me", "POST /api/auth/logout"])
    error_message = "identity_jwt_route_keys is not the sorted set of marked route keys."
  }

  assert {
    condition     = length(output.route_ids) == length(var.routes) + 1
    error_message = "The split between the two route resources lost or duplicated a route."
  }
}

run "production_extra_audiences_and_a_custom_name_are_honoured" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://api.example.com/api/auth"
      audience         = "example-production-api"
      name             = "example-custom-authorizer"
      audiences        = ["example-production-api", "example-production-cli"]
      identity_sources = ["$request.header.Authorization", "$request.header.X-Client"]
    }
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].name == "example-custom-authorizer"
    error_message = "A configured authorizer name was ignored."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].jwt_configuration[0].audience == toset(["example-production-api", "example-production-cli"])
    error_message = "A configured audiences list was ignored."
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt[0].identity_sources) == 2
    error_message = "A configured identity_sources list was ignored."
  }
}

run "staging_marks_change_no_route_and_the_keys_come_out_as_an_output" {
  command = plan

  variables {
    identity_jwt  = null
    authorizer_id = "abc123"
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt) == 0
    error_message = "No JWT authorizer may be created when identity_jwt is null."
  }

  assert {
    condition     = length(aws_apigatewayv2_route.identity_jwt) == 0
    error_message = "No route may move to the protected resource in staging: the gate's authorizer occupies the one slot a route has."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /api/auth/me"].authorization_type == "CUSTOM"
    error_message = "A marked route in staging must stay CUSTOM against the gate's authorizer."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /api/auth/me"].authorizer_id == "abc123"
    error_message = "A marked route in staging must carry the gate's authorizer id."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["ANY /api/v1/{proxy+}"].authorization_type == "CUSTOM"
    error_message = "The domain proxy route must stay behind the gate in staging."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /.well-known/jwks.json"].authorization_type == "NONE"
    error_message = "The JWKS route must stay anonymous even with the gate on."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /.well-known/jwks.json"].authorizer_id == null
    error_message = "A NONE route must carry no authorizer id, or every later plan shows a perpetual in-place update on it."
  }

  assert {
    condition     = output.identity_jwt_route_keys == tolist(["ANY /api/v1/{proxy+}", "GET /api/auth/me", "POST /api/auth/logout"])
    error_message = "identity_jwt_route_keys must still report the marked routes in staging: it is what the gate's Lambda enforces on."
  }

  assert {
    condition     = output.identity_jwt_authorizer_id == null
    error_message = "identity_jwt_authorizer_id must be null when no authorizer was created."
  }
}

run "an_authorizer_attached_to_no_route_is_refused" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "https://api.example.com/api/auth"
      audience = "example-production-api"
    }

    routes = {
      "GET /.well-known/jwks.json" = { integration = "identity", authorization_type = "NONE" }
    }
  }

  expect_failures = [aws_apigatewayv2_authorizer.identity_jwt]
}

run "requiring_a_token_on_a_route_forced_open_is_refused" {
  command = plan

  variables {
    routes = {
      "GET /api/auth/me" = {
        integration          = "identity"
        authorization_type   = "NONE"
        require_identity_jwt = true
      }
    }
  }

  expect_failures = [var.routes]
}

run "unset_inputs_create_nothing_and_mark_nothing" {
  command = plan

  variables {
    routes = {
      "ANY /api/v1/{proxy+}"   = { integration = "legacy" }
      "ANY /api/auth/{proxy+}" = { integration = "identity" }
    }
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt) == 0
    error_message = "An unset identity_jwt must create no authorizer."
  }

  assert {
    condition     = length(aws_apigatewayv2_route.identity_jwt) == 0
    error_message = "An unset identity_jwt must leave every route on the original resource."
  }

  assert {
    condition     = length(output.identity_jwt_route_keys) == 0
    error_message = "No route was marked, so identity_jwt_route_keys must be empty."
  }

  assert {
    condition     = !output.route_identity_jwt_required["ANY /api/v1/{proxy+}"]
    error_message = "An unmarked route must not report as requiring a token."
  }
}
