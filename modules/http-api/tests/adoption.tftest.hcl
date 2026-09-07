# Adoption from 1.x. These prove the two inputs an adopting consumer must get exactly right so that
# the plan reads "2 to move, 0 to add, 0 to change, 0 to destroy": the integration key is "legacy",
# which is the key the module's own moved blocks target, and the route keys are unchanged, which is
# what keeps every route at its 1.x address.

variables {
  name = "example-adopt-api"

  integrations = {
    legacy = {
      lambda_function_name = "example-adopt-api"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-adopt-api/invocations"
      timeout_milliseconds = 29000
    }
  }

  default_integration = "legacy"
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

# CarModPicker's 1.x shape: route_keys = ["$default"], one integration, the default statement id.
run "carmodpicker_shape" {
  command = plan

  assert {
    condition     = length(aws_apigatewayv2_route.this) == 1 && contains(keys(aws_apigatewayv2_route.this), "$default")
    error_message = "The CarModPicker shape must be exactly one route, at the same address it had in 1.x: aws_apigatewayv2_route.this[\"$default\"]."
  }

  assert {
    condition     = contains(keys(aws_apigatewayv2_integration.this), "legacy")
    error_message = "The integration must land at the \"legacy\" key, which is what the module's moved block targets."
  }

  assert {
    condition     = aws_lambda_permission.this["legacy"].statement_id == "AllowHttpApiInvoke"
    error_message = "CarModPicker's permission uses the default statement id; changing it would replace the permission."
  }
}

# WebbPulse-Portfolio's 1.x shape: two explicit route keys, no $default at all, and a custom
# statement id. Portfolio's monolith is reached through "ANY /{proxy+}" and "ANY /", so those two
# keys are its routes and default_integration is null; the addresses match 1.x exactly.
run "portfolio_shape" {
  command = plan

  variables {
    default_integration            = null
    lambda_permission_statement_id = "AllowAPIGatewayInvoke"

    integrations = {
      legacy = {
        lambda_function_name = "example-adopt-api"
        lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-adopt-api/invocations"
      }
    }

    routes = {
      "ANY /{proxy+}" = { integration = "legacy" }
      "ANY /"         = { integration = "legacy" }
    }
  }

  assert {
    condition     = length(aws_apigatewayv2_route.this) == 2
    error_message = "The Portfolio shape must be exactly its two 1.x routes and no synthesised $default."
  }

  assert {
    condition     = contains(keys(aws_apigatewayv2_route.this), "ANY /{proxy+}") && contains(keys(aws_apigatewayv2_route.this), "ANY /")
    error_message = "Both Portfolio route keys must keep their 1.x for_each keys, otherwise the routes are replaced."
  }

  assert {
    condition     = aws_lambda_permission.this["legacy"].statement_id == "AllowAPIGatewayInvoke"
    error_message = "The default integration must take lambda_permission_statement_id verbatim, so Portfolio's existing permission is not replaced."
  }
}

# And the first strangler step on top of the Portfolio shape: the monolith becomes the
# default_integration so it keeps catching everything, and one prefix moves. The two 1.x route keys
# are retired in the same change, which is a route replacement and is called out in the README.
run "portfolio_first_strangler_step" {
  command = plan

  variables {
    default_integration = "legacy"

    integrations = {
      legacy = {
        lambda_function_name = "example-adopt-api"
        lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-adopt-api/invocations"
      }
      posts = {
        lambda_function_name = "example-adopt-posts"
        lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-adopt-posts/invocations"
      }
    }

    routes = {
      "ANY /{proxy+}"              = { integration = "legacy" }
      "ANY /"                      = { integration = "legacy" }
      "ANY /api/v1/posts"          = { integration = "posts" }
      "ANY /api/v1/posts/{proxy+}" = { integration = "posts" }
    }
  }

  assert {
    condition     = output.route_integrations["ANY /api/v1/posts/{proxy+}"] == "posts"
    error_message = "The moved prefix must be served by its own function."
  }

  assert {
    condition     = output.route_integrations["ANY /{proxy+}"] == "legacy"
    error_message = "Portfolio's existing catch-all must keep pointing at the monolith while it exists."
  }

  assert {
    condition     = output.route_integrations["$default"] == "legacy"
    error_message = "$default must be the monolith so nothing falls through to a 404 mid-migration."
  }
}
