variables {
  name = "example-access-log-api"

  integrations = {
    legacy = {
      lambda_function_name = "example-access-log-legacy"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-access-log-legacy/invocations"
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

run "default_format_explains_an_authorizer_denial" {
  command = plan

  assert {
    condition     = strcontains(one(aws_apigatewayv2_stage.default.access_log_settings).format, "\"authorizerError\":\"$context.authorizer.error\"")
    error_message = "The default access log format must carry authorizerError so a 401 with no integration call explains itself."
  }

  assert {
    condition     = strcontains(one(aws_apigatewayv2_stage.default.access_log_settings).format, "\"errorMessage\":\"$context.error.message\"")
    error_message = "The default access log format must carry errorMessage."
  }

  assert {
    condition     = strcontains(one(aws_apigatewayv2_stage.default.access_log_settings).format, "\"errorType\":\"$context.error.responseType\"")
    error_message = "The default access log format must carry errorType."
  }

  assert {
    condition     = length(jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)) == 22
    error_message = "The default access log format should render 22 fields; an existing field was dropped."
  }
}

run "default_format_identifies_the_caller" {
  command = plan

  assert {
    condition     = jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)["jwtSub"] == "$context.authorizer.claims.sub"
    error_message = "The default access log format must carry jwtSub from the native JWT authorizer's claims."
  }

  assert {
    condition     = jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)["jwtSid"] == "$context.authorizer.claims.sid"
    error_message = "The default access log format must carry jwtSid from the native JWT authorizer's claims."
  }

  assert {
    condition     = jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)["lambdaSub"] == "$context.authorizer.sub"
    error_message = "The default access log format must carry lambdaSub from the shared identity Lambda authorizer's context."
  }

  assert {
    condition     = jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)["lambdaSid"] == "$context.authorizer.sid"
    error_message = "The default access log format must carry lambdaSid from the shared identity Lambda authorizer's context."
  }

  assert {
    condition     = jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)["authSource"] == "$context.authorizer.auth_source"
    error_message = "The default access log format must carry authSource from the shared identity Lambda authorizer's context."
  }

  assert {
    condition     = alltrue([for v in values(jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)) : !strcontains(lower(v), "email") && !strcontains(lower(v), "token") && !strcontains(lower(v), "header")])
    error_message = "The default access log format must never log an email, a token or a request header."
  }
}

run "a_caller_can_still_override_the_whole_format" {
  command = plan

  variables {
    access_log_format = {
      requestId = "$context.requestId"
    }
  }

  assert {
    condition     = jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format) == { requestId = "$context.requestId" }
    error_message = "An explicit access_log_format must replace the default outright, not merge with it."
  }
}
