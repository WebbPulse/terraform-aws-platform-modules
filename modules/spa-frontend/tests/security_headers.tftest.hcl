variables {
  name = "example-staging-frontend"
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

run "the_default_builds_a_security_headers_policy_with_csp_report_only" {
  command = plan

  override_resource {
    target          = aws_cloudfront_response_headers_policy.security
    override_during = plan
    values = {
      id = "11111111-2222-3333-4444-555555555555"
    }
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security) == 1
    error_message = "With response_headers_policy_id null the module must build its own policy, otherwise an adopter ships with no security headers at all, which is the PLAT-31 finding."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.security[0].name == "example-staging-frontend-security-headers"
    error_message = "The policy name must default to <name>-security-headers, which is unique per distribution because name is the bucket name."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].response_headers_policy_id == "11111111-2222-3333-4444-555555555555"
    error_message = "The module's policy must be attached to the default behavior, or building it changes nothing a viewer sees."
  }

  assert {
    condition = (
      aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].strict_transport_security[0].access_control_max_age_sec == 31536000 &&
      aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].strict_transport_security[0].include_subdomains &&
      !aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].strict_transport_security[0].preload
    )
    error_message = "HSTS must default to one year with includeSubDomains and without preload: preload is a near permanent commitment an adopter has to opt into."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].frame_options[0].frame_option == "DENY"
    error_message = "X-Frame-Options must be DENY so older browsers that ignore frame-ancestors still refuse to frame the site."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].referrer_policy[0].referrer_policy == "strict-origin-when-cross-origin"
    error_message = "Referrer-Policy must be strict-origin-when-cross-origin, so full URLs never leak to third parties."
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].content_type_options) == 1
    error_message = "X-Content-Type-Options nosniff must be sent."
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].content_security_policy) == 0
    error_message = "CSP defaults to report_only, so no enforcing Content-Security-Policy header may be sent: an upgrade must not block an adopter's third-party scripts."
  }

  assert {
    condition     = one(aws_cloudfront_response_headers_policy.security[0].custom_headers_config[0].items).header == "Content-Security-Policy-Report-Only"
    error_message = "In report_only mode the policy must travel as Content-Security-Policy-Report-Only, so violations are logged without blocking anything."
  }

  assert {
    condition     = one(aws_cloudfront_response_headers_policy.security[0].custom_headers_config[0].items).value == "default-src 'self'; connect-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    error_message = "The baseline CSP must be exactly the documented SPA baseline, with no frame-src, media-src or worker-src directive when their lists are empty."
  }

  assert {
    condition     = output.content_security_policy.mode == "report_only" && output.content_security_policy.header == "Content-Security-Policy-Report-Only"
    error_message = "The content_security_policy output must say how the policy is sent, so an adopter can check it before switching to enforce."
  }
}

run "enforce_mode_sends_the_csp_with_the_extra_sources" {
  command = plan

  variables {
    security_headers = {
      content_security_policy = {
        mode        = "enforce"
        connect_src = ["https://api.example.com"]
        script_src  = ["'sha256-abc='", "https://js.example.com"]
        frame_src   = ["https://frames.example.com"]
        report_uri  = "https://example.com/csp"
      }
    }
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security[0].custom_headers_config) == 0
    error_message = "In enforce mode no report-only header may be sent alongside the enforcing one."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].content_security_policy[0].content_security_policy == "default-src 'self'; connect-src 'self' https://api.example.com; img-src 'self' data:; script-src 'self' 'sha256-abc=' https://js.example.com; style-src 'self' 'unsafe-inline'; font-src 'self' data:; frame-src 'self' https://frames.example.com; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; report-uri https://example.com/csp"
    error_message = "Extra sources must be appended to their own directive after the baseline, frame-src must appear once it has sources, and report_uri must close the policy."
  }
}

run "csp_off_keeps_the_other_headers" {
  command = plan

  variables {
    security_headers = {
      content_security_policy = { mode = "off" }
    }
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].content_security_policy) == 0 && length(aws_cloudfront_response_headers_policy.security[0].custom_headers_config) == 0
    error_message = "mode off must send no CSP header of either kind."
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security[0].security_headers_config[0].strict_transport_security) == 1
    error_message = "Turning CSP off must not drop HSTS and the other headers."
  }

  assert {
    condition     = output.content_security_policy == null
    error_message = "The content_security_policy output must be null when no CSP is sent."
  }
}

run "an_explicit_policy_wins_in_forwarded_values_mode_on_every_s3_behavior" {
  command = plan

  variables {
    cache_mode                 = "forwarded_values"
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
    public_paths               = ["/robots.txt"]

    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    }
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security) == 0
    error_message = "An explicit response_headers_policy_id must replace the module's policy, not sit beside an unused one."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].response_headers_policy_id == "67f7725c-6f97-4210-82d7-5512b31e9d03"
    error_message = "The response headers policy must reach the default behavior in forwarded_values mode too; dropping it there is the PLAT-31 bug."
  }

  assert {
    condition = alltrue([
      for b in aws_cloudfront_distribution.this.ordered_cache_behavior :
      b.response_headers_policy_id == "67f7725c-6f97-4210-82d7-5512b31e9d03" if b.target_origin_id == "s3-frontend"
    ])
    error_message = "Every S3 behavior, the public_paths ones and the SPA shell included, must carry the policy, so no page on the site is served without headers."
  }

  assert {
    condition = alltrue([
      for b in aws_cloudfront_distribution.this.ordered_cache_behavior :
      (b.response_headers_policy_id == null || b.response_headers_policy_id == "") if b.target_origin_id == "access-gate-login"
    ])
    error_message = "The gate's login behavior must stay without the site's policy: the login Lambda sets its own headers and its pages carry an inline script a strict CSP would block."
  }

  assert {
    condition     = output.content_security_policy == null
    error_message = "With an explicit policy the module renders no CSP of its own, so the output must be null rather than describe a policy nobody receives."
  }
}

run "disabling_security_headers_builds_no_policy" {
  command = plan

  variables {
    security_headers = { enabled = false }
  }

  assert {
    condition     = length(aws_cloudfront_response_headers_policy.security) == 0
    error_message = "enabled = false must build no policy, which is the escape hatch back to the pre-2.37 behaviour."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].response_headers_policy_id == null
    error_message = "With no policy built and none passed, the default behavior must carry no response headers policy."
  }
}

run "an_unknown_csp_mode_is_rejected" {
  command = plan

  variables {
    security_headers = {
      content_security_policy = { mode = "block" }
    }
  }

  expect_failures = [var.security_headers]
}

run "a_source_carrying_a_semicolon_is_rejected" {
  command = plan

  variables {
    security_headers = {
      content_security_policy = { connect_src = ["https://api.example.com; script-src *"] }
    }
  }

  expect_failures = [var.security_headers]
}

run "preload_without_include_subdomains_is_rejected" {
  command = plan

  variables {
    security_headers = {
      hsts_preload            = true
      hsts_include_subdomains = false
    }
  }

  expect_failures = [var.security_headers]
}
