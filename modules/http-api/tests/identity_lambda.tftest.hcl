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
    "GET /.well-known/jwks.json" = { integration = "identity", authorization_type = "NONE" }
    "POST /api/auth/login"       = { integration = "identity" }

    "GET /api/auth/me"     = { integration = "identity", require_identity_jwt = true }
    "ANY /api/v1/{proxy+}" = { integration = "legacy", require_identity_jwt = true }
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

run "lambda_mode_builds_a_request_authorizer_and_no_native_one" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://api.example.com/api/auth"
      audience         = "example-production-api"
      mode             = "lambda"
      api_key_prefixes = ["wpk_"]
    }
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_jwt) == 0
    error_message = "lambda mode must create no native JWT authorizer; that is the one that refuses agent API keys."
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_lambda) == 1
    error_message = "lambda mode must create exactly one REQUEST authorizer."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_lambda[0].authorizer_type == "REQUEST"
    error_message = "The identity authorizer in lambda mode must be a REQUEST authorizer."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_lambda[0].enable_simple_responses
    error_message = "The authorizer must use simple responses: the handler answers isAuthorized, not an IAM policy."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_lambda[0].authorizer_payload_format_version == "2.0"
    error_message = "The authorizer must take payload format 2.0, which is what the handler reads."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_lambda[0].identity_sources == toset(["$request.header.Authorization"])
    error_message = "The authorizer must key its result cache on the Authorization header, or one caller's verdict would be served to another."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_lambda[0].authorizer_result_ttl_in_seconds == 300
    error_message = "The result cache must default to 300 seconds; without it every request pays a Lambda invocation."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_lambda[0].name == "example-test-api-identity-jwt"
    error_message = "The authorizer name must be the same default as in native mode, so a mode flip is not also a rename."
  }

  assert {
    condition     = alltrue([for _, r in aws_apigatewayv2_route.identity_jwt : r.authorization_type == "CUSTOM"])
    error_message = "A marked route in lambda mode must be CUSTOM: a REQUEST authorizer cannot sit behind authorization_type JWT."
  }

  assert {
    condition     = length(aws_apigatewayv2_route.identity_jwt) == 2
    error_message = "Both marked routes must move to the protected route resource in lambda mode, exactly as in native mode."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /.well-known/jwks.json"].authorization_type == "NONE"
    error_message = "The JWKS route must stay anonymous: the authorizer fetches it to verify tokens."
  }

  assert {
    condition     = aws_lambda_function.identity_lambda[0].function_name == "example-test-api-identity-authorizer"
    error_message = "The authorizer function name is not the default <var.name>-identity-authorizer."
  }

  assert {
    condition     = aws_lambda_function.identity_lambda[0].timeout == 10
    error_message = "The authorizer function timeout must stay 10 seconds, which is what the JWKS fetch timeout is checked against."
  }

  assert {
    condition     = aws_lambda_function.identity_lambda[0].environment[0].variables["IDENTITY_JWKS_URL"] == "https://api.example.com/api/auth/.well-known/jwks.json"
    error_message = "The JWKS URL must be derived from the issuer when none is given."
  }

  assert {
    condition     = aws_lambda_function.identity_lambda[0].environment[0].variables["IDENTITY_AUDIENCE"] == "example-production-api"
    error_message = "The audience must reach the function; a mismatch denies every token with nothing in the gateway log to say why."
  }

  assert {
    condition     = length(aws_lambda_permission.identity_lambda) == 1
    error_message = "The authorizer needs an invoke permission or API Gateway answers 500 on every enforced route."
  }

  assert {
    condition     = output.identity_jwt_mode == "lambda"
    error_message = "identity_jwt_mode must report lambda."
  }

  assert {
    condition     = output.identity_api_key_prefixes == tolist(["wpk_"])
    error_message = "The configured API key prefixes must be reported, so a product can assert the passthrough is really on."
  }

  assert {
    condition     = output.identity_authorizer_function_name == "example-test-api-identity-authorizer"
    error_message = "The authorizer function name must be an output, for finding its log group."
  }

  assert {
    condition     = output.identity_jwt_route_keys == tolist(["ANY /api/v1/{proxy+}", "GET /api/auth/me"])
    error_message = "identity_jwt_route_keys must still be the sorted marked keys: it is what the handler enforces on."
  }

  assert {
    condition     = length(output.route_ids) == length(var.routes) + 1
    error_message = "The split between the two route resources lost or duplicated a route."
  }
}

run "native_mode_stays_the_default_and_builds_nothing_new" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "https://api.example.com/api/auth"
      audience = "example-production-api"
    }
  }

  assert {
    condition     = output.identity_jwt_mode == "native"
    error_message = "mode must default to native, or an existing consumer's plan would not be empty."
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_lambda) == 0
    error_message = "native mode must create no REQUEST authorizer."
  }

  assert {
    condition     = length(aws_lambda_function.identity_lambda) == 0
    error_message = "native mode must create no authorizer function, which is the whole of its cost advantage."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.identity_lambda) == 0
    error_message = "native mode must create no authorizer log group."
  }

  assert {
    condition     = length(aws_iam_role.identity_lambda) == 0
    error_message = "native mode must create no authorizer role."
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_jwt[0].authorizer_type == "JWT"
    error_message = "native mode must still build the native JWT authorizer."
  }

  assert {
    condition     = alltrue([for _, r in aws_apigatewayv2_route.identity_jwt : r.authorization_type == "JWT"])
    error_message = "A marked route in native mode must still resolve to JWT."
  }

  assert {
    condition     = length(output.identity_api_key_prefixes) == 0
    error_message = "native mode admits no API key prefixes."
  }
}

run "a_result_cache_can_be_turned_off" {
  command = plan

  variables {
    identity_jwt = {
      issuer             = "https://api.example.com/api/auth"
      audience           = "example-production-api"
      mode               = "lambda"
      result_ttl_seconds = 0
    }
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.identity_lambda[0].authorizer_result_ttl_in_seconds == 0
    error_message = "result_ttl_seconds = 0 must disable the cache."
  }
}

run "api_key_prefixes_without_lambda_mode_are_refused" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://api.example.com/api/auth"
      audience         = "example-production-api"
      api_key_prefixes = ["wpk_"]
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_prefix_that_matches_a_jwt_is_refused" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://api.example.com/api/auth"
      audience         = "example-production-api"
      mode             = "lambda"
      api_key_prefixes = ["eyJ"]
    }
  }

  expect_failures = [var.identity_jwt]
}

run "an_unknown_mode_is_refused" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "https://api.example.com/api/auth"
      audience = "example-production-api"
      mode     = "gate"
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_jwks_fetch_timeout_over_the_function_budget_is_refused" {
  command = plan

  variables {
    identity_jwt = {
      issuer                = "https://api.example.com/api/auth"
      audience              = "example-production-api"
      mode                  = "lambda"
      jwks_fetch_timeout_ms = 9000
    }
  }

  expect_failures = [aws_lambda_function.identity_lambda]
}

run "lambda_mode_with_no_marked_route_is_refused" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "https://api.example.com/api/auth"
      audience = "example-production-api"
      mode     = "lambda"
    }

    routes = {
      "GET /.well-known/jwks.json" = { integration = "identity", authorization_type = "NONE" }
    }
  }

  expect_failures = [aws_apigatewayv2_authorizer.identity_lambda]
}

run "a_supplied_authorizer_id_still_wins_in_lambda_mode" {
  command = plan

  variables {
    identity_jwt = {
      issuer        = "https://api.example.com/api/auth"
      audience      = "example-production-api"
      mode          = "lambda"
      authorizer_id = "abc123"
    }
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.identity_lambda) == 0
    error_message = "A supplied authorizer_id must build no authorizer of our own, in either mode."
  }

  assert {
    condition     = length(aws_lambda_function.identity_lambda) == 0
    error_message = "A supplied authorizer_id must build no authorizer function."
  }

  assert {
    condition     = aws_apigatewayv2_route.identity_jwt["GET /api/auth/me"].authorizer_id == "abc123"
    error_message = "The supplied authorizer id must be the one attached to the marked routes."
  }
}
