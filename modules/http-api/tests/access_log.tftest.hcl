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
    condition     = length(jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)) == 17
    error_message = "The default access log format should render 17 fields; an existing field was dropped."
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
