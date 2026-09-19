variables {
  name           = "example-staging"
  cookie_domain  = "staging.example.com"
  site_host      = "www.staging.example.com"
  allowed_emails = ["owner@example.com"]

  identity_jwt = {
    issuer   = "https://www.staging.example.com/api/auth"
    audience = "example-staging-api"
  }

  identity_jwt_route_keys = ["ANY /api/v1/{proxy+}", "GET /api/auth/me"]
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

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

run "with_identity_jwt_null_the_authorizer_checks_only_the_gate_credentials" {
  command = plan

  variables {
    identity_jwt            = null
    identity_jwt_route_keys = []
  }

  assert {
    condition     = output.identity_jwt_enforced == false
    error_message = "identity_jwt defaults to null, which must leave the authorizer doing exactly what it did before the input existed: checking the origin header and the gate signed cookies and nothing more."
  }

  assert {
    condition     = length(output.identity_jwt_route_keys) == 0
    error_message = "With nothing enforced the echoed route key list must be empty, so a consumer asserting on it in a plan sees the off state rather than a stale set."
  }

  assert {
    condition     = !strcontains(aws_lambda_function.authorizer.description, "identity JWT")
    error_message = "The function description is the fastest way to tell which mode a deployed authorizer is in, so it must not claim identity enforcement when none is configured."
  }

  assert {
    condition     = length([for src in data.archive_file.authorizer.source : src.filename]) == 3
    error_message = "The handler, the shared identity verifier and the config file must all be bundled whether or not enforcement is on. Dropping the config when off would change the zip's shape between the two modes and make the off state a different deployment artifact rather than the same function with an empty route list."
  }
}

run "identity_jwt_without_route_keys_enforces_nothing" {
  command = plan

  variables {
    identity_jwt_route_keys = []
  }

  assert {
    condition     = output.identity_jwt_enforced == false
    error_message = "Both halves are required: an issuer and audience with no route to apply them to is a configuration a consumer is mid-way through writing, and enforcing it on every route would take the API down."
  }

  assert {
    condition     = length(output.identity_jwt_route_keys) == 0
    error_message = "With no routes named the echoed list must stay empty, so the output never suggests enforcement a half configured module is not doing."
  }

  assert {
    condition     = !strcontains(aws_lambda_function.authorizer.description, "identity JWT")
    error_message = "An issuer with no routes must leave the authorizer describing itself as the plain gate, because that is exactly what it still is."
  }
}

run "route_keys_without_identity_jwt_enforce_nothing" {
  command = plan

  variables {
    identity_jwt = null
  }

  assert {
    condition     = output.identity_jwt_enforced == false
    error_message = "Route keys alone name routes with no issuer to verify against. Treating that as enabled would mean denying every request on those routes, which is worse than the open state the consumer had."
  }

  assert {
    condition     = length(output.identity_jwt_route_keys) == 0
    error_message = "Route keys must not be echoed while nothing verifies a token on them: a consumer reading the output would otherwise believe those routes are protected."
  }
}

run "both_halves_together_turn_enforcement_on" {
  command = plan

  assert {
    condition     = output.identity_jwt_enforced
    error_message = "An issuer, an audience and at least one route key is the whole condition for enforcement, and the output is what a consumer asserts on to prove staging is actually requiring identity tokens."
  }

  assert {
    condition     = strcontains(aws_lambda_function.authorizer.description, "identity JWT")
    error_message = "With enforcement on the description must say so, since the two modes are otherwise the same function name, runtime and handler and nothing in the console would distinguish them."
  }

  assert {
    condition     = strcontains(aws_lambda_function.authorizer.description, "identity_jwt_config.json")
    error_message = "The description must name the config file, because the route list that decides enforcement per request lives in the zip rather than in the function's environment where a responder would look first."
  }
}

run "the_route_keys_reach_the_output_sorted" {
  command = plan

  assert {
    condition     = tolist(output.identity_jwt_route_keys) == tolist(["ANY /api/v1/{proxy+}", "GET /api/auth/me"])
    error_message = "The route keys must be sorted. The same list is bundled into the zip and hashed into source_code_hash, so an unsorted order would redeploy the authorizer every time the consumer's route map happened to iterate differently."
  }

  assert {
    condition     = length(output.identity_jwt_route_keys) == length(var.identity_jwt_route_keys)
    error_message = "Sorting must not drop or add entries: the echoed set has to be exactly the set the consumer asked for, since it is what they assert their API's protected routes against."
  }
}

run "a_route_key_set_given_out_of_order_is_echoed_in_sorted_order" {
  command = plan

  variables {
    identity_jwt_route_keys = ["GET /api/auth/me", "ANY /api/v1/{proxy+}"]
  }

  assert {
    condition     = tolist(output.identity_jwt_route_keys) == tolist(["ANY /api/v1/{proxy+}", "GET /api/auth/me"])
    error_message = "Two consumers passing the same set in different orders must get the same output and the same function artifact, which is what keeps a route map reshuffle from looking like a code change."
  }
}

run "the_config_file_is_bundled_beside_the_handler" {
  command = plan

  assert {
    condition     = contains([for src in data.archive_file.authorizer.source : src.filename], "identity_jwt_config.json")
    error_message = "The route keys, the gate's public key and the anonymous prefixes must travel as a file in the zip rather than as environment variables, because a multi-line PEM does not belong in a function's configuration and the route list can grow past what an environment variable comfortably holds."
  }

  assert {
    condition     = contains([for src in data.archive_file.authorizer.source : src.filename], "index.js")
    error_message = "The handler itself must be in the zip; without index.js the function has nothing to run no matter how the config is shaped."
  }

  assert {
    condition     = contains([for src in data.archive_file.authorizer.source : src.filename], "identity.js")
    error_message = "The shared identity verifier must be bundled beside the handler. It is the same file the http-api module packages, and without it the handler cannot require it and every token fails closed at runtime on a green plan."
  }
}

run "an_issuer_that_is_not_https_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "http://www.staging.example.com/api/auth"
      audience = "example-staging-api"
    }
  }

  expect_failures = [var.identity_jwt]
}

run "an_issuer_with_a_trailing_slash_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "https://www.staging.example.com/api/auth/"
      audience = "example-staging-api"
    }
  }

  expect_failures = [var.identity_jwt]
}

run "an_empty_audience_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer   = "https://www.staging.example.com/api/auth"
      audience = ""
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_zero_jwks_ttl_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://www.staging.example.com/api/auth"
      audience         = "example-staging-api"
      jwks_ttl_seconds = 0
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_negative_clock_skew_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer             = "https://www.staging.example.com/api/auth"
      audience           = "example-staging-api"
      clock_skew_seconds = -1
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_route_key_that_is_not_method_and_path_is_rejected" {
  command = plan

  variables {
    identity_jwt_route_keys = ["/api/auth/me"]
  }

  expect_failures = [var.identity_jwt_route_keys]
}

run "requiring_an_identity_token_on_the_default_route_is_rejected" {
  command = plan

  variables {
    identity_jwt_route_keys = ["$default"]
  }

  expect_failures = [var.identity_jwt_route_keys]
}

run "a_route_key_containing_a_comma_is_rejected" {
  command = plan

  variables {
    identity_jwt_route_keys = ["GET /api/auth/me,/api/auth/you"]
  }

  expect_failures = [var.identity_jwt_route_keys]
}

run "a_duplicated_route_key_is_rejected" {
  command = plan

  variables {
    identity_jwt_route_keys = ["GET /api/auth/me", "GET /api/auth/me"]
  }

  expect_failures = [var.identity_jwt_route_keys]
}

run "an_anonymous_prefix_without_a_leading_slash_is_rejected" {
  command = plan

  variables {
    identity_anonymous_path_prefixes = ["api/auth/.well-known/"]
  }

  expect_failures = [var.identity_anonymous_path_prefixes]
}

run "an_explicit_empty_anonymous_prefix_list_is_accepted" {
  command = plan

  variables {
    identity_anonymous_path_prefixes = []
  }

  assert {
    condition     = output.identity_jwt_enforced
    error_message = "Passing an empty prefix list must be a valid configuration rather than a rejected one: a consumer whose JWKS is served from somewhere the gate does not guard wants no hole in the gate at all, and removing the default exemption must not disable enforcement."
  }
}

run "the_packaged_config_carries_an_empty_api_key_prefix_list_by_default" {
  command = plan

  assert {
    condition     = length(local.identity_api_key_prefixes) == 0
    error_message = "api_key_prefixes must always be present in the packaged config and empty unless a consumer asks for prefixes, so an authorizer built without the field denies every non-JWT bearer exactly as it did before."
  }
}

run "configured_api_key_prefixes_reach_the_packaged_config" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://www.staging.example.com/api/auth"
      audience         = "example-staging-api"
      api_key_prefixes = ["wpk_"]
    }
  }

  assert {
    condition     = join(",", local.identity_api_key_prefixes) == "wpk_"
    error_message = "The prefixes decide which bearers skip the token check, so they must travel in the zip beside the route keys rather than being dropped on the way to the function."
  }
}

run "an_empty_api_key_prefix_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://www.staging.example.com/api/auth"
      audience         = "example-staging-api"
      api_key_prefixes = [""]
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_jwt_shaped_api_key_prefix_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer           = "https://www.staging.example.com/api/auth"
      audience         = "example-staging-api"
      api_key_prefixes = ["eyJ"]
    }
  }

  expect_failures = [var.identity_jwt]
}

run "the_packaged_config_carries_the_default_jwks_fetch_timeout" {
  command = plan

  assert {
    condition     = local.identity_jwks_fetch_timeout_ms == 4000
    error_message = "The JWKS fetch timeout must default to 4000 ms and travel in the zip: a cold identity function takes about two seconds to serve the key set, and a shorter deadline aborts the fetch so the first authorized call after the TTL expires is denied with authorizerError=Forbidden."
  }

  assert {
    condition     = aws_lambda_function.authorizer.timeout * 1000 >= local.identity_jwks_fetch_timeout_ms + 4000
    error_message = "The authorizer function timeout must exceed the JWKS fetch timeout with room to retry once and verify the signature, otherwise the invocation is killed mid-verification and a valid token is refused."
  }
}

run "a_configured_jwks_fetch_timeout_reaches_the_packaged_config" {
  command = plan

  variables {
    identity_jwt = {
      issuer                = "https://www.staging.example.com/api/auth"
      audience              = "example-staging-api"
      jwks_fetch_timeout_ms = 2500
    }
  }

  assert {
    condition     = local.identity_jwks_fetch_timeout_ms == 2500
    error_message = "A consumer whose identity function is slower or faster than the default must be able to set the fetch deadline, so the configured value has to reach the packaged config rather than being dropped."
  }
}

run "a_jwks_fetch_timeout_below_the_floor_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer                = "https://www.staging.example.com/api/auth"
      audience              = "example-staging-api"
      jwks_fetch_timeout_ms = 200
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_jwks_fetch_timeout_over_the_function_timeout_is_rejected" {
  command = plan

  variables {
    identity_jwt = {
      issuer                = "https://www.staging.example.com/api/auth"
      audience              = "example-staging-api"
      jwks_fetch_timeout_ms = 12000
    }
  }

  expect_failures = [var.identity_jwt]
}

run "a_jwks_fetch_timeout_without_headroom_is_refused_at_plan_time" {
  command = plan

  variables {
    identity_jwt = {
      issuer                = "https://www.staging.example.com/api/auth"
      audience              = "example-staging-api"
      jwks_fetch_timeout_ms = 9000
    }
  }

  expect_failures = [aws_lambda_function.authorizer]
}
