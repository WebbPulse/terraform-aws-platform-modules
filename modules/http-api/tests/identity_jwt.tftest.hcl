# Plan-only tests for require_identity_jwt and the two mechanisms behind it. Every run block is
# `command = plan` against literal inputs, so this suite talks to no AWS API and needs no
# credentials.
#
# What it proves:
#   * with identity_jwt set, a marked route is JWT against this module's own authorizer and an
#     unmarked one is untouched;
#   * with identity_jwt null, which is staging, nothing about any route changes and the route keys
#     come out as an output for the gate to enforce instead;
#   * the anonymous identity routes stay anonymous in both shapes, which is what API Gateway's own
#     discovery document fetch depends on;
#   * the module refuses the two configurations that would be enforcement nobody gets.

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

  # The identity surface as both consumers will write it: the anonymous flows that have to answer
  # without a token, and the authenticated ones that must not.
  routes = {
    # Anonymous. API Gateway's CreateAuthorizer fetches these two itself, with no credentials.
    "GET /.well-known/openid-configuration" = { integration = "identity", authorization_type = "NONE" }
    "GET /.well-known/jwks.json"            = { integration = "identity", authorization_type = "NONE" }

    # Anonymous: a caller with no token yet is the entire point of each of them.
    "POST /api/auth/login"    = { integration = "identity" }
    "POST /api/auth/refresh"  = { integration = "identity" }
    "POST /api/auth/register" = { integration = "identity" }

    # Authenticated.
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

# ---------------------------------------------------------------------------
# Production: the native JWT authorizer
# ---------------------------------------------------------------------------

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

  # The three marked routes are on the protected resource, created after the authorizer.
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

  # And the anonymous ones are untouched and carry no authorizer at all.
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

  # Every route still exists exactly once across the two resources.
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

# ---------------------------------------------------------------------------
# Staging: the gate authorizer stays, and the route keys come out as an output
# ---------------------------------------------------------------------------

run "staging_marks_change_no_route_and_the_keys_come_out_as_an_output" {
  command = plan

  variables {
    identity_jwt  = null
    authorizer_id = "abc123"

    # The two .well-known routes still have to be anonymous under the gate, which is what the
    # explicit NONE in the shared routes map says. Everything else is the gate's.
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt) == 0
    error_message = "No JWT authorizer may be created when identity_jwt is null."
  }

  assert {
    condition     = length(aws_apigatewayv2_route.identity_jwt) == 0
    error_message = "No route may move to the protected resource in staging: the gate's authorizer occupies the one slot a route has."
  }

  # A marked route is CUSTOM against the gate, byte for byte what it is without the mark.
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

  # The .well-known routes stay open even under the gate: they are the deliberate hole.
  assert {
    condition     = aws_apigatewayv2_route.this["GET /.well-known/jwks.json"].authorization_type == "NONE"
    error_message = "The JWKS route must stay anonymous even with the gate on."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /.well-known/jwks.json"].authorizer_id == null
    error_message = "A NONE route must carry no authorizer id, or every later plan shows a perpetual in-place update on it."
  }

  # This is the whole staging wiring: this output into the gate's identity_jwt_route_keys.
  assert {
    condition     = output.identity_jwt_route_keys == tolist(["ANY /api/v1/{proxy+}", "GET /api/auth/me", "POST /api/auth/logout"])
    error_message = "identity_jwt_route_keys must still report the marked routes in staging: it is what the gate's Lambda enforces on."
  }

  assert {
    condition     = output.identity_jwt_authorizer_id == null
    error_message = "identity_jwt_authorizer_id must be null when no authorizer was created."
  }
}

# ---------------------------------------------------------------------------
# The two configurations that would be enforcement nobody gets
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Doing nothing at all, which is what every existing consumer gets
# ---------------------------------------------------------------------------

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
