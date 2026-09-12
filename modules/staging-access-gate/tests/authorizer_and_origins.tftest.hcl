variables {
  name           = "example-staging"
  cookie_domain  = "staging.example.com"
  site_host      = "www.staging.example.com"
  allowed_emails = ["owner@example.com"]
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

run "without_an_http_api_id_no_gateway_authorizer_is_created" {
  command = plan

  assert {
    condition     = length(aws_apigatewayv2_authorizer.origin_verify) == 0
    error_message = "http_api_id defaults to null because a consumer may adopt the gate before their API exists, and an authorizer resource with no api_id to attach to cannot plan at all."
  }

  assert {
    condition     = length(aws_lambda_permission.authorizer) == 0
    error_message = "The invoke permission must appear only alongside the authorizer: its source ARN names the authorizer id, so creating it without one would grant API Gateway invoke on a resource that does not exist."
  }

  assert {
    condition     = output.http_api_authorizer_id == null
    error_message = "The authorizer id output must be null rather than an error in this branch, since consumers feed it straight into a route's authorizer_id and need to be able to tell the two branches apart."
  }
}

run "an_http_api_id_creates_a_request_authorizer_that_inspects_the_whole_request" {
  command = plan

  variables {
    http_api_id = "abc123def4"
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.origin_verify) == 1
    error_message = "Passing an API id must create exactly one authorizer, which is what stops the API being callable directly on its execute-api hostname, bypassing CloudFront and the gate entirely."
  }

  assert {
    condition     = one(aws_apigatewayv2_authorizer.origin_verify).authorizer_type == "REQUEST"
    error_message = "It must be a REQUEST authorizer rather than a JWT one: what is being checked is a custom header and a pair of signed cookies, neither of which a JWT authorizer can read."
  }

  assert {
    condition     = one(aws_apigatewayv2_authorizer.origin_verify).authorizer_payload_format_version == "2.0" && one(aws_apigatewayv2_authorizer.origin_verify).enable_simple_responses
    error_message = "The payload format and simple responses must match what the authorizer code returns. A 2.0 event with simple responses lets the function answer with isAuthorized, and a mismatch here makes every request fail with an internal authorizer error rather than a 403."
  }

  assert {
    condition     = length(coalesce(one(aws_apigatewayv2_authorizer.origin_verify).identity_sources, [])) == 0
    error_message = "Identity sources must be empty, whether rendered as an empty list or as nothing at all. Naming one makes API Gateway refuse any request missing it before the function runs, and the gate deliberately wants CORS preflights, which carry no cookies, to reach the function and be allowed."
  }

  assert {
    condition     = one(aws_apigatewayv2_authorizer.origin_verify).authorizer_result_ttl_in_seconds == 0
    error_message = "Caching must be off. With identity_sources empty there is no cache key that distinguishes one viewer from another, so any non zero TTL would let one authorized response be reused for everybody."
  }

  assert {
    condition     = length(aws_lambda_permission.authorizer) == 1
    error_message = "API Gateway cannot invoke a Lambda authorizer without a resource policy statement, so the permission must be created in exactly this branch."
  }

  assert {
    condition     = one(aws_lambda_permission.authorizer).principal == "apigateway.amazonaws.com"
    error_message = "The permission must be granted to the API Gateway service principal and no other, since a wider principal would let anything in the account invoke the authorizer directly."
  }

  assert {
    condition     = one(aws_apigatewayv2_authorizer.origin_verify).name == "example-staging-access-gate-origin-verify"
    error_message = "The authorizer name must be derived from name, because two applications sharing one account would otherwise be indistinguishable in the API Gateway console."
  }
}

run "without_a_distribution_arn_the_function_url_admits_any_distribution_in_the_account" {
  command = plan

  assert {
    condition     = aws_lambda_permission.login_url.source_arn == "arn:aws:cloudfront::123456789012:distribution/*"
    error_message = "When the consuming distribution also consumes this module's outputs, naming it here is a dependency cycle, so the permission must fall back to a wildcard scoped to the account's own partition and account id rather than to no condition at all."
  }

  assert {
    condition     = aws_lambda_permission.login_url.principal == "cloudfront.amazonaws.com"
    error_message = "Only CloudFront may invoke the login function URL: the URL's own auth type is AWS_IAM, and this statement is the entirety of what makes the origin reachable."
  }

  assert {
    condition     = aws_lambda_permission.login_url.function_url_auth_type == "AWS_IAM"
    error_message = "The permission must be scoped to the AWS_IAM auth type. A statement that omits it would also cover a NONE-auth URL, which is a publicly invokable login endpoint."
  }
}

run "an_explicit_distribution_arn_narrows_the_function_url_permission_to_that_distribution" {
  command = plan

  variables {
    cloudfront_distribution_arn = "arn:aws:cloudfront::123456789012:distribution/E1EXAMPLE0001"
  }

  assert {
    condition     = aws_lambda_permission.login_url.source_arn == "arn:aws:cloudfront::123456789012:distribution/E1EXAMPLE0001"
    error_message = "A consumer that can name the distribution without a cycle must get the narrow grant, because the wildcard admits every distribution in the account and a second application's distribution could otherwise drive this login flow."
  }
}

run "the_login_function_url_is_signed_rather_than_public" {
  command = plan

  assert {
    condition     = aws_lambda_function_url.login.authorization_type == "AWS_IAM"
    error_message = "A function URL with NONE authorization is a public HTTPS endpoint anyone can hit. The login handler mints signed cookies, so it must only be reachable through a SigV4 signed CloudFront origin request."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.login.signing_behavior == "always" && aws_cloudfront_origin_access_control.login.signing_protocol == "sigv4"
    error_message = "The origin access control must always SigV4-sign: the function URL rejects unsigned requests, so a never or no-override signing behavior makes every login attempt a 403 from Lambda."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.login.origin_access_control_origin_type == "lambda"
    error_message = "The origin type must be lambda rather than s3, because the service name that goes into the SigV4 credential scope is derived from it and an s3-scoped signature is not one Lambda accepts."
  }
}

run "the_retention_a_consumer_sets_reaches_both_lambda_log_groups" {
  command = plan

  variables {
    log_retention_days = 30
  }

  assert {
    condition     = aws_cloudwatch_log_group.authorizer.retention_in_days == 30
    error_message = "log_retention_days must reach the authorizer group. This module creates both groups precisely so retention is bounded rather than left at the never-expiring default Lambda applies to a group it creates itself."
  }

  assert {
    condition     = aws_cloudwatch_log_group.login.retention_in_days == 30
    error_message = "The same value must reach the login group. One input governing two groups is the point: a consumer who set retention and still found one group growing without limit would have no way to tell from the module interface."
  }
}

run "a_retention_of_zero_means_never_expire_on_both_groups" {
  command = plan

  variables {
    log_retention_days = 0
  }

  assert {
    condition     = aws_cloudwatch_log_group.authorizer.retention_in_days == 0 && aws_cloudwatch_log_group.login.retention_in_days == 0
    error_message = "Zero is CloudWatch Logs' encoding of never expire, and it must pass through untouched rather than being coalesced away as a falsy value, because an investigation that needs logs older than the usual window has no other way to ask for them."
  }
}

run "the_default_retention_is_a_value_cloudwatch_logs_accepts" {
  command = plan

  assert {
    condition = contains([
      0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096,
      1827, 2192, 2557, 2922, 3288, 3653,
    ], aws_cloudwatch_log_group.authorizer.retention_in_days)
    error_message = "Whatever the default retention is, it must be one of the values CloudWatch Logs accepts. Any other number is rejected at apply time rather than at plan, so a consumer who never touched this input would discover it only when the deployment failed."
  }

  assert {
    condition     = aws_cloudwatch_log_group.login.retention_in_days == aws_cloudwatch_log_group.authorizer.retention_in_days
    error_message = "Both groups must share the default too, so the two halves of one gate are never retained for different periods and a correlated investigation is not missing one side."
  }
}

run "a_retention_cloudwatch_logs_does_not_accept_is_rejected" {
  command = plan

  variables {
    log_retention_days = 13
  }

  expect_failures = [var.log_retention_days]
}

run "the_path_prefixes_reach_the_outputs_as_cache_behavior_patterns" {
  command = plan

  assert {
    condition     = output.auth_path_pattern == "/_auth/*"
    error_message = "auth_path_pattern is what the consumer puts on the ordered cache behavior that routes to the login origin, and it must be the prefix plus a wildcard: a pattern without the wildcard matches only the bare prefix and the callback never reaches the Lambda."
  }

  assert {
    condition     = output.api_path_pattern == "/api/*"
    error_message = "api_path_pattern is the behavior that carries the origin verification header to the API, so a wrong pattern means API requests take the default behavior and arrive at the API without the header the authorizer requires."
  }
}

run "custom_path_prefixes_reach_the_outputs_and_the_viewer_request_function" {
  command = plan

  variables {
    auth_path_prefix = "/_gate/"
    api_path_prefix  = "/backend/"
  }

  assert {
    condition     = output.auth_path_pattern == "/_gate/*" && output.api_path_pattern == "/backend/*"
    error_message = "Both prefixes must be overridable together, because a site whose own routes already claim /_auth/ or /api/ has to move the gate out of the way rather than fork the module."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.gate.code, "/_gate/")
    error_message = "The viewer-request function decides where to send a viewer with no session, so it must be built with the same auth prefix the cache behavior uses or the redirect lands on a path that routes to S3."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.gate.code, "/backend/")
    error_message = "The function must know the API prefix too: that is how it answers an unauthenticated API call with a 401 JSON body instead of redirecting a fetch to an HTML login page."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.gate.comment, "/_gate/login")
    error_message = "The function comment names the login path it redirects to, and it must be built from the same prefix so the console description does not describe a gate the consumer is not running."
  }
}

run "without_a_custom_handler_the_function_carries_a_pass_through_app_handler" {
  command = plan

  assert {
    condition     = strcontains(aws_cloudfront_function.gate.code, "function appHandler(event) { return event.request; }")
    error_message = "viewer_request_handler_js defaults to empty, and the template still calls appHandler, so a no-op definition must be substituted: an undefined function reference is a runtime error on every single viewer request."
  }
}

run "a_custom_viewer_request_handler_replaces_the_pass_through" {
  command = plan

  variables {
    viewer_request_handler_js = "function appHandler(event) { event.request.uri = '/rewritten'; return event.request; }"
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.gate.code, "'/rewritten'")
    error_message = "A consumer's handler must be embedded verbatim. Both consumers use this slot for apex-to-www redirects and URI rewrites, which have to run before the gate check so a redirect is not gated behind a login."
  }

  assert {
    condition     = !strcontains(aws_cloudfront_function.gate.code, "function appHandler(event) { return event.request; }")
    error_message = "The default must be replaced rather than appended. Two definitions of appHandler in one CloudFront function means the second wins silently, which would make the consumer's handler either dead code or the only one that runs depending on order."
  }
}

run "the_session_length_is_configurable_and_the_defaults_are_published" {
  command = plan

  variables {
    session_hours = 24
  }

  assert {
    condition     = output.cache_policy_id_caching_disabled == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    error_message = "The login and API behaviors must never cache, and the module publishes the managed CachingDisabled id so a consumer does not hardcode a policy id whose meaning they cannot check."
  }

  assert {
    condition     = output.origin_request_policy_id_all_viewer_except_host_header == "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    error_message = "AllViewerExceptHostHeader is the policy that forwards the session cookies and the authorization header to the origin while letting the Lambda function URL see its own hostname, and publishing the id keeps the consumer's behavior and this module's expectations in step."
  }

  assert {
    condition     = output.origin_verify_header_name == "x-origin-verify"
    error_message = "The header name is shared between the consumer's origin custom header and this module's authorizer, so it must be published rather than agreed by convention on both sides."
  }

  assert {
    condition     = output.origin_verify_ssm_parameter_name == "/example-staging/access-gate/origin-verify"
    error_message = "A pipeline that needs to call the API host directly reads the shared secret from this parameter, so its name must be an output rather than a path the consumer reconstructs from the naming convention."
  }
}

run "a_session_shorter_than_an_hour_is_rejected" {
  command = plan

  variables {
    session_hours = 0
  }

  expect_failures = [var.session_hours]
}

run "a_session_longer_than_a_week_is_rejected" {
  command = plan

  variables {
    session_hours = 169
  }

  expect_failures = [var.session_hours]
}

run "an_auth_path_prefix_without_a_trailing_slash_is_rejected" {
  command = plan

  variables {
    auth_path_prefix = "/_auth"
  }

  expect_failures = [var.auth_path_prefix]
}

run "a_bare_slash_auth_path_prefix_is_rejected" {
  command = plan

  variables {
    auth_path_prefix = "/"
  }

  expect_failures = [var.auth_path_prefix]
}

run "an_api_path_prefix_without_a_leading_slash_is_rejected" {
  command = plan

  variables {
    api_path_prefix = "api/"
  }

  expect_failures = [var.api_path_prefix]
}
