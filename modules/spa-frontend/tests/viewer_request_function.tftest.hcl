variables {
  name    = "example-production-frontend"
  aliases = ["www.example.com", "example.com"]

  acm_certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/00000000-0000-0000-0000-000000000000"
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

run "without_the_input_no_function_is_built" {
  command = plan

  assert {
    condition     = length(aws_cloudfront_function.viewer_request) == 0
    error_message = "A consumer that does not set viewer_request_function must build no function."
  }

  assert {
    condition     = output.viewer_request_handler_js == null
    error_message = "viewer_request_handler_js must be null without the input."
  }
}

run "a_www_canonical_host_redirects_the_apex_and_names_the_function_after_the_module" {
  command = plan

  variables {
    viewer_request_function = {
      domain         = "example.com"
      canonical_host = "www"
    }
  }

  assert {
    condition     = length(aws_cloudfront_function.viewer_request) == 1
    error_message = "viewer_request_function must build exactly one function."
  }

  assert {
    condition     = aws_cloudfront_function.viewer_request[0].name == "example-production-frontend-uri-rewrite"
    error_message = "The default function name must be <name>-uri-rewrite so an adopting product keeps its existing name."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.viewer_request[0].code, "if (host === 'example.com')")
    error_message = "A www canonical host must redirect requests arriving at the apex."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.viewer_request[0].code, "https://www.example.com")
    error_message = "A www canonical host must redirect to the www hostname."
  }

  assert {
    condition     = strcontains(output.viewer_request_handler_js, "function appHandler(event)")
    error_message = "viewer_request_handler_js must expose the appHandler for a gate to wrap."
  }
}

run "an_apex_canonical_host_redirects_www" {
  command = plan

  variables {
    viewer_request_function = {
      domain = "example.com"
    }
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.viewer_request[0].code, "if (host === 'www.example.com')")
    error_message = "The apex default must redirect requests arriving at www."
  }
}

run "no_canonical_host_writes_no_redirect" {
  command = plan

  variables {
    viewer_request_function = {
      domain         = "example.com"
      canonical_host = "none"
    }
  }

  assert {
    condition     = !strcontains(aws_cloudfront_function.viewer_request[0].code, "statusCode: 301")
    error_message = "canonical_host none must render no redirect."
  }
}

run "the_gate_takes_the_slot_and_the_handler_is_still_rendered" {
  command = plan

  variables {
    viewer_request_function = {
      domain = "example.com"
    }

    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-production-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    }
  }

  assert {
    condition     = length(aws_cloudfront_function.viewer_request) == 0
    error_message = "With a gate the module must not build its own function."
  }

  assert {
    condition     = output.viewer_request_handler_js != null
    error_message = "The handler must still render for the gate to wrap."
  }
}

run "both_inputs_are_refused" {
  command = plan

  variables {
    viewer_request_function_arn = "arn:aws:cloudfront::123456789012:function/example-production-frontend-uri-rewrite"

    viewer_request_function = {
      domain = "example.com"
    }
  }

  expect_failures = [aws_cloudfront_function.viewer_request]
}

run "a_www_prefixed_domain_is_refused" {
  command = plan

  variables {
    viewer_request_function = {
      domain = "www.example.com"
    }
  }

  expect_failures = [var.viewer_request_function]
}

run "an_unknown_canonical_host_is_refused" {
  command = plan

  variables {
    viewer_request_function = {
      domain         = "example.com"
      canonical_host = "both"
    }
  }

  expect_failures = [var.viewer_request_function]
}
