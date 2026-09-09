# Plan-only tests. They never talk to AWS: every run block is `command = plan` and the inputs are
# literal ARNs, so `terraform test` here needs credentials for nothing.
#
# What they prove is the thing the Portfolio inventory flagged: on this module it is not possible to
# end up with a route that has no authorization while the access gate is on, $default included.

variables {
  name = "example-test-api"

  integrations = {
    legacy = {
      lambda_function_name = "example-test-legacy"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-test-legacy/invocations"
    }
    posts = {
      lambda_function_name = "example-test-posts"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-test-posts/invocations"
    }
  }

  default_integration = "legacy"

  routes = {
    "ANY /api/v1/posts"          = { integration = "posts" }
    "ANY /api/v1/posts/{proxy+}" = { integration = "posts" }
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

run "default_route_exists_and_targets_the_default_integration" {
  command = plan

  assert {
    condition     = contains(keys(aws_apigatewayv2_route.this), "$default")
    error_message = "The module did not create a $default route for default_integration."
  }

  assert {
    condition     = output.route_integrations["$default"] == "legacy"
    error_message = "$default is not served by the default_integration."
  }

  assert {
    condition     = output.route_integrations["ANY /api/v1/posts"] == "posts"
    error_message = "The posts collection route is not served by the posts integration."
  }

  assert {
    condition     = output.route_integrations["ANY /api/v1/posts/{proxy+}"] == "posts"
    error_message = "The posts item route is not served by the posts integration."
  }
}

run "one_integration_and_one_permission_per_backend" {
  command = plan

  assert {
    condition     = length(aws_apigatewayv2_integration.this) == 2
    error_message = "Expected one integration per integrations entry."
  }

  assert {
    condition     = length(aws_lambda_permission.this) == 2
    error_message = "Expected one invoke permission per integrations entry."
  }

  assert {
    condition     = aws_lambda_permission.this["legacy"].statement_id == "AllowHttpApiInvoke"
    error_message = "The default integration's permission must keep the bare lambda_permission_statement_id so an adopting consumer's permission is not replaced."
  }

  assert {
    condition     = aws_lambda_permission.this["posts"].statement_id == "AllowHttpApiInvoke-posts"
    error_message = "A non-default integration's permission must get a key-suffixed statement id, otherwise two permissions collide on one function."
  }
}

run "without_an_authorizer_every_route_is_none" {
  command = plan

  assert {
    condition     = alltrue([for k, r in aws_apigatewayv2_route.this : r.authorization_type == "NONE"])
    error_message = "With authorizer_id unset every route should be NONE."
  }
}

run "with_the_gate_on_every_route_including_default_is_custom" {
  command = plan

  variables {
    authorizer_id                = "abc123"
    domain_name                  = "api.example.com"
    certificate_arn              = "arn:aws:acm:us-west-2:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    disable_execute_api_endpoint = true
  }

  assert {
    condition     = alltrue([for k, r in aws_apigatewayv2_route.this : r.authorization_type == "CUSTOM"])
    error_message = "With the access gate on, every route must be CUSTOM. A route created without one silently defaults to no authorization, which is a hole straight through the gate."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["$default"].authorization_type == "CUSTOM"
    error_message = "$default must carry the gate's authorizer too; it is the route that answers everything the prefixes do not."
  }

  assert {
    condition     = alltrue([for k, r in aws_apigatewayv2_route.this : r.authorizer_id == "abc123"])
    error_message = "Every route must reference the module's authorizer_id."
  }

  assert {
    condition     = aws_apigatewayv2_api.this.disable_execute_api_endpoint
    error_message = "disable_execute_api_endpoint did not reach the API."
  }
}

run "a_route_can_opt_out_of_the_gate_deliberately" {
  command = plan

  variables {
    authorizer_id = "abc123"

    routes = {
      "ANY /api/v1/posts"          = { integration = "posts" }
      "ANY /api/v1/posts/{proxy+}" = { integration = "posts" }
      "GET /health"                = { integration = "legacy", authorization_type = "NONE" }
    }
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /health"].authorization_type == "NONE"
    error_message = "An explicit authorization_type override should win over the module-wide choice."
  }

  # A NONE route must carry no authorizer id at all. API Gateway accepts the create with one
  # attached and then stores nothing, so a route that keeps the gate's id in configuration reads
  # back as "" from the API and shows a perpetual in-place update on every later plan.
  assert {
    condition     = aws_apigatewayv2_route.this["GET /health"].authorizer_id == null
    error_message = "A route opting out with authorization_type NONE must get no authorizer_id, otherwise every later plan shows a perpetual authorizer_id \"\" -> id update on it."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["$default"].authorization_type == "CUSTOM"
    error_message = "One route opting out must not change any other route."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["$default"].authorizer_id == "abc123"
    error_message = "One route opting out must not strip the authorizer from any other route."
  }
}

# The shape Portfolio staging needs: the access gate is on, but the two .well-known documents have
# to be public because the API Gateway JWT authorizer fetches them anonymously. Opting those routes
# out must leave them with no authorizer id, and must not disturb the gated routes beside them.
run "public_well_known_routes_carry_no_authorizer_id" {
  command = plan

  variables {
    authorizer_id = "p5vo7t"

    routes = {
      "ANY /api/v1/posts" = { integration = "posts" }
      "GET /.well-known/jwks.json" = {
        integration        = "legacy"
        authorization_type = "NONE"
      }
      "GET /.well-known/openid-configuration" = {
        integration        = "legacy"
        authorization_type = "NONE"
      }
    }
  }

  assert {
    condition = alltrue([
      for k in ["GET /.well-known/jwks.json", "GET /.well-known/openid-configuration"] :
      aws_apigatewayv2_route.this[k].authorization_type == "NONE" && aws_apigatewayv2_route.this[k].authorizer_id == null
    ])
    error_message = "The public .well-known routes must be NONE with no authorizer_id, so the JWT authorizer can fetch them anonymously and no plan drifts on them."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["ANY /api/v1/posts"].authorizer_id == "p5vo7t"
    error_message = "The gated routes must keep the module's authorizer_id."
  }
}

# AWS_IAM takes no authorizer either, and the module-wide authorizer_id must not leak onto it.
run "an_aws_iam_route_carries_no_authorizer_id" {
  command = plan

  variables {
    authorizer_id = "abc123"

    routes = {
      "ANY /api/v1/posts" = { integration = "posts" }
      "POST /internal/reindex" = {
        integration        = "legacy"
        authorization_type = "AWS_IAM"
      }
    }
  }

  assert {
    condition     = aws_apigatewayv2_route.this["POST /internal/reindex"].authorization_type == "AWS_IAM"
    error_message = "An AWS_IAM override should win over the module-wide choice."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["POST /internal/reindex"].authorizer_id == null
    error_message = "An AWS_IAM route takes no authorizer, so it must get no authorizer_id."
  }
}

# The per-route authorizer_id override is for pointing one route at a different authorizer, and it
# must keep working for the two types that actually take one.
run "a_per_route_authorizer_id_override_still_wins_for_custom_and_jwt" {
  command = plan

  variables {
    authorizer_id = "gate01"

    routes = {
      "ANY /api/v1/posts" = { integration = "posts" }
      "GET /partner/feed" = {
        integration   = "legacy"
        authorizer_id = "partner99"
      }
      "GET /jwt/thing" = {
        integration          = "legacy"
        authorization_type   = "JWT"
        authorizer_id        = "jwt42"
        authorization_scopes = ["read:posts"]
      }
    }
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /partner/feed"].authorizer_id == "partner99"
    error_message = "A per-route authorizer_id override must win over var.authorizer_id on a CUSTOM route."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["GET /jwt/thing"].authorizer_id == "jwt42"
    error_message = "A per-route authorizer_id override must win over var.authorizer_id on a JWT route."
  }

  assert {
    condition     = aws_apigatewayv2_route.this["ANY /api/v1/posts"].authorizer_id == "gate01"
    error_message = "A route without an override must still get var.authorizer_id."
  }
}

# With no gate at all every route is NONE, so nothing on the API may carry an authorizer id. This is
# the case where a stray per-route authorizer_id would otherwise be attached to a NONE route.
run "without_an_authorizer_no_route_carries_an_authorizer_id" {
  command = plan

  variables {
    routes = {
      "ANY /api/v1/posts" = { integration = "posts" }
      "GET /partner/feed" = {
        integration   = "legacy"
        authorizer_id = "partner99"
      }
    }
  }

  assert {
    condition     = alltrue([for k, r in aws_apigatewayv2_route.this : r.authorizer_id == null])
    error_message = "With no authorization on any route, no route may carry an authorizer_id."
  }
}

run "no_default_route_when_default_integration_is_null" {
  command = plan

  variables {
    default_integration = null

    integrations = {
      posts = {
        lambda_function_name = "example-test-posts"
        lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-test-posts/invocations"
      }
    }

    routes = {
      "ANY /api/v1/posts"          = { integration = "posts" }
      "ANY /api/v1/posts/{proxy+}" = { integration = "posts" }
    }
  }

  assert {
    condition     = !contains(keys(aws_apigatewayv2_route.this), "$default")
    error_message = "default_integration = null should create no $default route."
  }

  assert {
    condition     = output.default_integration_id == null
    error_message = "default_integration_id should be null when there is no default integration."
  }
}

# A routes entry naming an integration that does not exist fails with a message that names the
# route and the bad key, instead of a raw "Invalid index" on the target expression.
run "an_unknown_integration_fails_by_name" {
  command = plan

  variables {
    integrations = {
      legacy = {
        lambda_function_name = "example-test-legacy"
        lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-test-legacy/invocations"
      }
    }

    default_integration = "legacy"

    routes = {
      "GET /posts" = { integration = "typo_posts" }
    }
  }

  expect_failures = [aws_apigatewayv2_route.this]
}

# default_integration still defaults to "legacy". A consumer that names its backend something else
# and forgets the input gets the named precondition, not an Invalid index inside an output.
run "a_default_integration_that_names_nothing_fails_by_name" {
  command = plan

  variables {
    integrations = {
      monolith = {
        lambda_function_name = "example-test-monolith"
        lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-test-monolith/invocations"
      }
    }

    routes = {
      "GET /health" = { integration = "monolith" }
    }
  }

  expect_failures = [aws_apigatewayv2_route.this]
}
