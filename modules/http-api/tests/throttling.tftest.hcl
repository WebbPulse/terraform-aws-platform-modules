variables {
  name = "example-throttle-api"

  integrations = {
    legacy = {
      lambda_function_name = "example-throttle-legacy"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-throttle-legacy/invocations"
    }
    reports = {
      lambda_function_name   = "example-throttle-reports"
      lambda_invoke_arn      = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-throttle-reports/invocations"
      timeout_milliseconds   = 29000
      payload_format_version = "1.0"
    }
  }

  default_integration = "legacy"

  routes = {
    "ANY /api/v1/reports/{proxy+}" = { integration = "reports" }
  }

  throttling_burst_limit = 200
  throttling_rate_limit  = 100

  route_settings = {
    "ANY /api/v1/reports/{proxy+}" = {
      throttling_burst_limit   = 5
      throttling_rate_limit    = 2
      detailed_metrics_enabled = true
    }
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

run "stage_defaults_and_per_route_override" {
  command = plan

  assert {
    condition     = one(aws_apigatewayv2_stage.default.default_route_settings).throttling_burst_limit == 200
    error_message = "The stage default burst limit did not come through."
  }

  assert {
    condition     = one(aws_apigatewayv2_stage.default.default_route_settings).throttling_rate_limit == 100
    error_message = "The stage default rate limit did not come through."
  }

  assert {
    condition     = length(aws_apigatewayv2_stage.default.route_settings) == 1
    error_message = "Expected exactly one per-route settings block."
  }

  assert {
    condition     = one([for s in aws_apigatewayv2_stage.default.route_settings : s.throttling_rate_limit if s.route_key == "ANY /api/v1/reports/{proxy+}"]) == 2
    error_message = "The per-route rate limit did not reach the stage."
  }
}

run "per_integration_overrides_reach_the_integration" {
  command = plan

  assert {
    condition     = aws_apigatewayv2_integration.this["reports"].timeout_milliseconds == 29000
    error_message = "A per-integration timeout override did not reach the integration."
  }

  assert {
    condition     = aws_apigatewayv2_integration.this["reports"].payload_format_version == "1.0"
    error_message = "A per-integration payload_format_version override did not reach the integration."
  }

  assert {
    condition     = aws_apigatewayv2_integration.this["legacy"].payload_format_version == "2.0"
    error_message = "An integration without an override should inherit var.payload_format_version."
  }

  assert {
    condition     = local.resolved_integrations["legacy"].timeout_milliseconds == null
    error_message = "An integration without a timeout override should leave the service default unwritten, so an adopting consumer's 30000 in state is left alone."
  }
}

run "webhook_and_mcp_routes_capped_under_a_raised_stage_default" {
  command = plan

  variables {
    routes = {
      "POST /api/github/webhooks" = { integration = "legacy" }
      "ANY /api/mcp"              = { integration = "reports" }
    }

    throttling_burst_limit = 1000
    throttling_rate_limit  = 500

    route_settings = {
      "POST /api/github/webhooks" = {
        throttling_burst_limit = 40
        throttling_rate_limit  = 20
      }
      "ANY /api/mcp" = {
        throttling_rate_limit = 50
      }
    }
  }

  assert {
    condition     = one(aws_apigatewayv2_stage.default.default_route_settings).throttling_rate_limit == 500
    error_message = "The raised stage default did not come through."
  }

  assert {
    condition     = one([for s in aws_apigatewayv2_stage.default.route_settings : s.throttling_burst_limit if s.route_key == "POST /api/github/webhooks"]) == 40
    error_message = "The webhook route burst cap did not reach the stage."
  }

  assert {
    condition     = one([for s in aws_apigatewayv2_stage.default.route_settings : s.throttling_rate_limit if s.route_key == "ANY /api/mcp"]) == 50
    error_message = "The MCP route rate cap did not reach the stage."
  }

  assert {
    condition     = one([for s in aws_apigatewayv2_stage.default.route_settings : s.throttling_burst_limit if s.route_key == "ANY /api/mcp"]) == 1000
    error_message = "An omitted per-route burst must inherit the stage burst; the provider would otherwise write 0 and throttle the route shut."
  }

  assert {
    condition     = one([for s in aws_apigatewayv2_stage.default.route_settings : s.detailed_metrics_enabled if s.route_key == "ANY /api/mcp"]) == false
    error_message = "An omitted per-route detailed_metrics_enabled must inherit the stage value."
  }
}

run "an_explicit_zero_still_blocks_the_route" {
  command = plan

  variables {
    route_settings = {
      "ANY /api/v1/reports/{proxy+}" = {
        throttling_burst_limit = 0
        throttling_rate_limit  = 0
      }
    }
  }

  assert {
    condition     = one([for s in aws_apigatewayv2_stage.default.route_settings : s.throttling_rate_limit if s.route_key == "ANY /api/v1/reports/{proxy+}"]) == 0
    error_message = "An explicit 0 must stay 0 so a consumer can still shut a route."
  }
}

run "no_route_settings_writes_no_route_settings_blocks" {
  command = plan

  variables {
    route_settings = {}
  }

  assert {
    condition     = length(aws_apigatewayv2_stage.default.route_settings) == 0
    error_message = "An empty route_settings must write no per-route block, so a consumer that sets none sees no plan change."
  }
}
