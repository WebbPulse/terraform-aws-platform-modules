variables {
  name = "example-staging-frontend"

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

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "without_a_gate_nothing_of_the_gate_topology_is_rendered" {
  command = plan

  variables {
    access_gate                 = null
    viewer_request_function_arn = "arn:aws:cloudfront::123456789012:function/example-staging-apex-redirect"
  }

  assert {
    condition     = length([for o in aws_cloudfront_distribution.this.origin : o.origin_id]) == 1
    error_message = "With no gate the distribution must have the S3 origin alone: the login origin exists only to serve the gate's Lambda function URL."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.ordered_cache_behavior) == 0
    error_message = "With no gate there must be no ordered behaviors at all. Every ordered behavior this module renders belongs to the gate, so a production distribution stays a single behavior distribution."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior[0].function_association).function_arn == "arn:aws:cloudfront::123456789012:function/example-staging-apex-redirect"
    error_message = "Without a gate the consumer's own viewer_request_function_arn must be associated, since that is how both consumers run their apex to www redirect in production."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.custom_error_response) == 2 && alltrue([for r in aws_cloudfront_distribution.this.custom_error_response : r.response_page_path == "/index.html" && r.response_code == 200])
    error_message = "Without a gate both 403 and 404 must still fall back to the shell, so a production distribution plans no change from the gate's 403 handling."
  }

  assert {
    condition     = length(local.bucket_policy_statements) == 1 && local.bucket_policy_statements[0].Action == "s3:GetObject"
    error_message = "Without a gate the bucket policy must keep its single GetObject statement, so a production bucket policy plans no change."
  }
}

run "a_gate_sends_a_refused_request_to_the_sign_in_page_rather_than_the_shell" {
  command = plan

  assert {
    condition = length([
      for r in aws_cloudfront_distribution.this.custom_error_response : r
      if r.error_code == 403 && r.response_code == 403 && r.response_page_path == "/_auth/session-required" && r.error_caching_min_ttl == 0
    ]) == 1
    error_message = "With a gate, 403 must serve the gate's sign-in-required page with a 403. CloudFront answers a missing session with 403 before the viewer-request function runs, and falling back to the shell gives a deep link a 200 whose bundle is also the shell as HTML: a blank page with no redirect."
  }

  assert {
    condition = length([
      for r in aws_cloudfront_distribution.this.custom_error_response : r
      if r.response_page_path == "/index.html"
    ]) == 1 && one([for r in aws_cloudfront_distribution.this.custom_error_response : r.error_code if r.response_page_path == "/index.html"]) == 404
    error_message = "With a gate only 404 may fall back to the shell. A 403 mapped to the shell as well would be a duplicate error code, and it is the very path that dead-ends an unauthenticated deep link."
  }

  assert {
    condition     = length(local.bucket_policy_statements) == 2 && local.bucket_policy_statements[1].Action == "s3:ListBucket" && local.bucket_policy_statements[1].Sid == "AllowCloudFrontListForMissingKeys"
    error_message = "With a gate CloudFront needs s3:ListBucket on the bucket, so a missing key is a 404 that falls back to the shell. Without it a signed-in viewer's deep link is an S3 403, which now goes to the sign-in page and bounces through login."
  }
}

run "an_explicit_session_required_path_is_used_for_the_403_page" {
  command = plan

  variables {
    spa_fallback_error_codes = [403, 404, 503]
    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_gate/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
      session_required_path                                  = "/_gate/needed"
    }
  }

  assert {
    condition     = one([for r in aws_cloudfront_distribution.this.custom_error_response : r.response_page_path if r.error_code == 403]) == "/_gate/needed"
    error_message = "access_gate.session_required_path must reach the 403 custom error response when a consumer sets it."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.custom_error_response) == 3
    error_message = "A consumer's explicit fallback codes must survive with 403 taken out and replaced by the sign-in page, not dropped wholesale."
  }
}

run "a_session_required_path_outside_the_auth_pattern_is_rejected" {
  command = plan

  variables {
    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
      session_required_path                                  = "/index.html"
    }
  }

  expect_failures = [var.access_gate]
}

run "no_viewer_request_function_is_associated_when_the_consumer_passes_none" {
  command = plan

  variables {
    access_gate = null
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.default_cache_behavior[0].function_association) == 0
    error_message = "viewer_request_function_arn defaults to null and must then render no function_association at all: an empty association block is rejected by CloudFront rather than ignored."
  }
}

run "a_gate_adds_the_login_origin_and_requires_a_session_on_the_default_behavior" {
  command = plan

  assert {
    condition     = length([for o in aws_cloudfront_distribution.this.origin : o.origin_id]) == 2
    error_message = "A gate must add exactly one origin, the login function URL. A third origin would mean proxy mode was entered without the consumer asking for it."
  }

  assert {
    condition = one([
      for o in aws_cloudfront_distribution.this.origin : o if o.origin_id == "access-gate-login"
    ]).domain_name == "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
    error_message = "The login origin must point at the gate's function URL hostname, and login_origin_id must default to access-gate-login so a consumer that names nothing still gets a working origin."
  }

  assert {
    condition = one(one([
      for o in aws_cloudfront_distribution.this.origin : o if o.origin_id == "access-gate-login"
    ]).custom_origin_config).origin_protocol_policy == "https-only"
    error_message = "The login origin must be reached over HTTPS only. The authorization code and the cookie signing response cross that hop, and a match-viewer policy would let a plain HTTP viewer downgrade it."
  }

  assert {
    condition = one([
      for o in aws_cloudfront_distribution.this.origin : o if o.origin_id == "access-gate-login"
    ]).origin_access_control_id == "E1EXAMPLEOAC1"
    error_message = "The login origin must carry the gate's origin access control, because the function URL is AWS_IAM authorized and an unsigned request to it is simply refused."
  }

  assert {
    condition     = tolist(aws_cloudfront_distribution.this.default_cache_behavior[0].trusted_key_groups) == tolist(["1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"])
    error_message = "The default behavior must trust the gate's key group. That is the entire enforcement of the gate on site content: without it CloudFront serves the staging site to anyone who asks."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior[0].function_association).function_arn == "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
    error_message = "The gate's function must be the one associated on the default behavior: it is what turns a missing cookie into a redirect to the login page rather than a bare 403."
  }
}

run "the_gate_function_replaces_rather_than_joins_the_consumers_own_function" {
  command = plan

  variables {
    viewer_request_function_arn = "arn:aws:cloudfront::123456789012:function/example-staging-apex-redirect"
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.default_cache_behavior[0].function_association) == 1
    error_message = "CloudFront allows only one viewer-request function per behavior, so the module must pick one rather than render both and fail the apply."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior[0].function_association).function_arn == "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
    error_message = "When a gate is attached the gate's function must win. The consumer's own handler is not lost: it is passed to the gate as viewer_request_handler_js and the gate's function runs it first."
  }
}

run "the_auth_behavior_routes_to_the_login_origin_uncached_and_unsigned" {
  command = plan

  assert {
    condition     = length(aws_cloudfront_distribution.this.ordered_cache_behavior) == 2
    error_message = "Without proxy mode a gate must render exactly two ordered behaviors, the auth path and the SPA shell. A third would mean an API behavior appeared with no API origin behind it."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[0].path_pattern == "/_auth/*"
    error_message = "The auth behavior must come first in the ordered list: CloudFront evaluates ordered behaviors in order, and a later SPA shell match would swallow the login callback."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[0].target_origin_id == "access-gate-login"
    error_message = "The auth path must reach the login Lambda rather than the bucket, since S3 has no object at /_auth/callback and would answer the SPA fallback instead of exchanging the code."
  }

  assert {
    condition     = length(coalesce(aws_cloudfront_distribution.this.ordered_cache_behavior[0].trusted_key_groups, [])) == 0
    error_message = "The auth behavior must not require a signed cookie. It is the path a viewer takes to obtain one, so gating it would make sign-in impossible for exactly the viewers who need it."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[0].cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    error_message = "The auth behavior must use the CachingDisabled policy: caching a Set-Cookie response would hand one viewer's session to the next."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[0].origin_request_policy_id == "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    error_message = "AllViewerExceptHostHeader is required so the query string carrying the authorization code reaches the Lambda while the Host header stays the function URL's own, which the SigV4 signature is computed over."
  }

  assert {
    condition     = contains(aws_cloudfront_distribution.this.ordered_cache_behavior[0].allowed_methods, "OPTIONS")
    error_message = "The auth behavior must allow OPTIONS so a browser preflight against the login endpoint is answered rather than rejected by CloudFront before the Lambda sees it."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.ordered_cache_behavior[0].function_association).function_arn == "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
    error_message = "The gate function must run on the auth behavior too, because it is what recognises the auth prefix and lets the request through untouched instead of redirecting it back to the login page in a loop."
  }
}

run "the_spa_shell_behavior_is_servable_without_a_session" {
  command = plan

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].path_pattern == "/index.html"
    error_message = "The unsigned behavior must be exactly the SPA shell path derived from default_root_object, because the browser has to be able to load the shell before it has a cookie in order to be redirected to sign in."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].target_origin_id == "s3-frontend"
    error_message = "The shell comes from the bucket like every other object; only its signing requirement differs."
  }

  assert {
    condition     = length(coalesce(aws_cloudfront_distribution.this.ordered_cache_behavior[1].trusted_key_groups, [])) == 0
    error_message = "The SPA shell behavior must carry no key group. It is the one object served to a viewer with no session, and requiring a signed cookie for it makes the redirect to the login page a 403 nobody can act on."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.ordered_cache_behavior[1].function_association).function_arn == "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
    error_message = "The gate function must still run on the shell behavior: leaving it off would serve the shell to anyone and never send them through Cognito."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].cache_policy_id == "658327ea-f89d-4fab-a63d-7e88639e58f6"
    error_message = "index_cache_mode defaults to cache_mode, so under the default policy model the shell behavior must reuse cache_policy_id and a consumer who never set the input sees no change."
  }
}

run "the_shell_behavior_can_use_the_policy_model_while_the_default_behavior_stays_legacy" {
  command = plan

  variables {
    cache_mode           = "forwarded_values"
    index_cache_mode     = "policies"
    index_cache_policies = { cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" }
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.default_cache_behavior[0].forwarded_values) == 1
    error_message = "The default behavior must stay on the legacy model, which is the whole reason index_cache_mode exists: Portfolio's live distribution mixes the two and adopting it must not rewrite the default behavior."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.ordered_cache_behavior[1].forwarded_values) == 0
    error_message = "The shell behavior must render no legacy block once index_cache_mode is policies, because CloudFront rejects a behavior that carries both models."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].cache_policy_id == "658327ea-f89d-4fab-a63d-7e88639e58f6"
    error_message = "index_cache_policies.cache_policy_id must reach the shell behavior, since that is the exact shape a hand-written SPA shell behavior has and matching it is what makes the adoption plan quiet."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].origin_request_policy_id == null && aws_cloudfront_distribution.this.ordered_cache_behavior[1].response_headers_policy_id == null
    error_message = "Setting index_cache_policies must pin the shell behavior on its own, including to no origin request and no response headers policy. Falling back to the top level inputs here would add policies the live behavior does not have."
  }
}

run "the_shell_behavior_inherits_the_top_level_policies_when_index_cache_policies_is_null" {
  command = plan

  variables {
    origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].origin_request_policy_id == "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    error_message = "With index_cache_policies null the shell behavior must reuse origin_request_policy_id, which is what every consumer written before that input existed already gets."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].response_headers_policy_id == "67f7725c-6f97-4210-82d7-5512b31e9d03"
    error_message = "The shell is the document every security header applies to, so it must inherit response_headers_policy_id rather than serve the one page on the site without them."
  }
}

run "proxy_mode_adds_the_api_origin_its_behavior_and_the_verification_header" {
  command = plan

  variables {
    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

      api_origin_domain_name    = "abcdef1234.execute-api.us-west-2.amazonaws.com"
      api_path_pattern          = "/api/*"
      origin_verify_header_name = "x-origin-verify"
    }

    access_gate_origin_verify_header_value = "example-origin-verify-value"
  }

  assert {
    condition     = length([for o in aws_cloudfront_distribution.this.origin : o.origin_id]) == 3
    error_message = "Proxy mode must add a third origin for the API, which is what lets the frontend call the API same-origin instead of cross-origin."
  }

  assert {
    condition = one([
      for o in aws_cloudfront_distribution.this.origin : o if o.origin_id == "api"
    ]).domain_name == "abcdef1234.execute-api.us-west-2.amazonaws.com"
    error_message = "The API origin must point at the API Gateway hostname, and api_origin_id must default to api so a consumer that names nothing still gets a working origin."
  }

  assert {
    condition = one(one([
      for o in aws_cloudfront_distribution.this.origin : o if o.origin_id == "api"
    ]).custom_header).name == "x-origin-verify"
    error_message = "The API origin must carry the origin verification header, because the gate's HTTP API authorizer admits only requests bearing it and would otherwise refuse everything CloudFront proxies."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.ordered_cache_behavior) == 3
    error_message = "Proxy mode must add exactly one ordered behavior for the API path, on top of the auth and shell behaviors."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].path_pattern == "/api/*"
    error_message = "The API behavior must sit between the auth behavior and the SPA shell behavior, so the auth path still wins and the shell never claims an API path."
  }

  assert {
    condition     = tolist(aws_cloudfront_distribution.this.ordered_cache_behavior[1].trusted_key_groups) == tolist(["1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"])
    error_message = "The API behavior must require a signed cookie like the site itself: proxying the API through the distribution must not become a way around the gate."
  }

  assert {
    condition     = contains(aws_cloudfront_distribution.this.ordered_cache_behavior[1].allowed_methods, "POST") && contains(aws_cloudfront_distribution.this.ordered_cache_behavior[1].allowed_methods, "DELETE")
    error_message = "The API behavior must allow the write methods. The site origin serves reads only, but an API that cannot be POSTed to is not an API."
  }

  assert {
    condition     = tolist(aws_cloudfront_distribution.this.ordered_cache_behavior[1].cached_methods) == tolist(["GET", "HEAD"])
    error_message = "Only GET and HEAD may be cacheable methods even when writes are allowed; caching a write response is not something CloudFront supports."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[1].cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    error_message = "The API behavior must use CachingDisabled: caching an authenticated API response at the edge would serve one user's data to another."
  }
}

run "an_auth_path_pattern_that_is_not_a_cloudfront_pattern_is_rejected" {
  command = plan

  variables {
    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    }
  }

  expect_failures = [var.access_gate]
}

run "half_a_proxy_configuration_is_rejected" {
  command = plan

  variables {
    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

      api_origin_domain_name = "abcdef1234.execute-api.us-west-2.amazonaws.com"
    }
  }

  expect_failures = [var.access_gate]
}

run "a_login_origin_id_that_collides_with_the_s3_origin_is_rejected" {
  command = plan

  variables {
    origin_id = "example-staging-frontend-s3"

    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

      login_origin_id = "example-staging-frontend-s3"
    }
  }

  expect_failures = [var.access_gate]
}

run "an_api_origin_id_that_collides_with_the_login_origin_is_rejected" {
  command = plan

  variables {
    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

      api_origin_domain_name    = "abcdef1234.execute-api.us-west-2.amazonaws.com"
      api_path_pattern          = "/api/*"
      origin_verify_header_name = "x-origin-verify"
      api_origin_id             = "access-gate-login"
    }

    access_gate_origin_verify_header_value = "example-origin-verify-value"
  }

  expect_failures = [var.access_gate]
}

run "proxy_mode_without_the_origin_verify_value_is_rejected" {
  command = plan

  variables {
    access_gate = {
      key_group_id                                           = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      viewer_request_function_arn                            = "arn:aws:cloudfront::123456789012:function/example-staging-access-gate"
      login_origin_domain_name                               = "abcdefghijklmnopqrstuvwxyz012345.lambda-url.us-west-2.on.aws"
      login_origin_access_control_id                         = "E1EXAMPLEOAC1"
      auth_path_pattern                                      = "/_auth/*"
      cache_policy_id_caching_disabled                       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

      api_origin_domain_name    = "abcdef1234.execute-api.us-west-2.amazonaws.com"
      api_path_pattern          = "/api/*"
      origin_verify_header_name = "x-origin-verify"
    }
  }

  expect_failures = [var.access_gate_origin_verify_header_value]
}

run "an_index_cache_mode_that_is_not_one_of_the_two_models_is_rejected" {
  command = plan

  variables {
    index_cache_mode = "managed"
  }

  expect_failures = [var.index_cache_mode]
}

run "index_cache_policies_without_a_cache_policy_is_rejected" {
  command = plan

  variables {
    index_cache_policies = {
      response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
    }
  }

  expect_failures = [var.index_cache_policies]
}
