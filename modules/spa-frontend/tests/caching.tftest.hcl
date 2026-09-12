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

run "the_policy_model_is_the_default_and_leaves_the_legacy_ttls_unset" {
  command = plan

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].cache_policy_id == "658327ea-f89d-4fab-a63d-7e88639e58f6"
    error_message = "cache_mode defaults to policies, so the default behavior must carry the AWS managed CachingOptimized policy id rather than nothing: a policy behavior with no cache policy is rejected by CloudFront."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.default_cache_behavior[0].forwarded_values) == 0
    error_message = "Under the policy model no forwarded_values block may be rendered. CloudFront rejects a behavior that carries both a cache policy and the legacy block, so the two must be mutually exclusive rather than merely preferred."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].origin_request_policy_id == null && aws_cloudfront_distribution.this.default_cache_behavior[0].response_headers_policy_id == null
    error_message = "origin_request_policy_id and response_headers_policy_id default to null: they are genuinely optional, and forcing a managed default on them would change the headers every existing consumer's site serves."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].compress
    error_message = "The default behavior must compress: a SPA bundle is text, and serving it uncompressed multiplies first paint transfer for every viewer."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https"
    error_message = "Plain HTTP viewers must be redirected rather than served, because the access gate's session cookies only travel over HTTPS and a plain HTTP hit would look like a signed-out viewer."
  }

  assert {
    condition     = tolist(aws_cloudfront_distribution.this.default_cache_behavior[0].allowed_methods) == tolist(["GET", "HEAD"])
    error_message = "An S3 static site answers reads only, so allowing anything beyond GET and HEAD would advertise methods the origin can only fail."
  }
}

run "the_managed_policies_a_consumer_passes_reach_the_default_behavior" {
  command = plan

  variables {
    origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].origin_request_policy_id == "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    error_message = "CarModPicker pins the managed CORS-S3Origin origin request policy, so the input must land on the default behavior verbatim or the adopted distribution plans a change on every apply."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].response_headers_policy_id == "67f7725c-6f97-4210-82d7-5512b31e9d03"
    error_message = "CarModPicker pins the managed SecurityHeadersPolicy, so dropping this input would silently stop the site sending its security headers."
  }
}

run "forwarded_values_mode_renders_the_legacy_block_and_no_policies" {
  command = plan

  variables {
    cache_mode = "forwarded_values"
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].cache_policy_id == null
    error_message = "Under forwarded_values no cache policy may be set: CloudFront rejects a behavior carrying both models, and Portfolio's adopted distribution is on the legacy model."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.default_cache_behavior[0].forwarded_values) == 1
    error_message = "Under forwarded_values exactly one legacy block must be rendered, because that block is what tells the origin which query strings and cookies reach it."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].forwarded_values[0].query_string == false
    error_message = "The forwarded_values defaults must reproduce a distribution that forwards no query string: forwarding one would fragment the cache key of every static asset."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].forwarded_values[0].cookies[0].forward == "none"
    error_message = "Cookies must default to none. Forwarding the access gate session cookie into the S3 cache key would give every signed-in viewer their own copy of every object."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].min_ttl == 0 && aws_cloudfront_distribution.this.default_cache_behavior[0].default_ttl == 86400 && aws_cloudfront_distribution.this.default_cache_behavior[0].max_ttl == 31536000
    error_message = "The legacy TTL defaults must be 0, 86400 and 31536000, which is the shape of the hand-written distribution this mode exists to adopt without a diff."
  }
}

run "explicit_forwarded_values_settings_reach_the_behavior" {
  command = plan

  variables {
    cache_mode = "forwarded_values"

    forwarded_values = {
      query_string    = true
      cookies_forward = "whitelist"
      headers         = ["Origin"]
      min_ttl         = 10
      default_ttl     = 300
      max_ttl         = 600
    }
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].forwarded_values[0].query_string
    error_message = "query_string must plumb through, because a site that routes on a query parameter breaks outright if CloudFront strips it from the cache key and the origin request."
  }

  assert {
    condition     = tolist(aws_cloudfront_distribution.this.default_cache_behavior[0].forwarded_values[0].headers) == tolist(["Origin"])
    error_message = "headers must plumb through: Origin in the cache key is how a legacy distribution serves correct CORS responses to more than one site host."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].min_ttl == 10 && aws_cloudfront_distribution.this.default_cache_behavior[0].default_ttl == 300 && aws_cloudfront_distribution.this.default_cache_behavior[0].max_ttl == 600
    error_message = "All three TTLs must plumb through together, since the whole point of the legacy mode is reproducing an existing distribution's caching byte for byte."
  }
}

run "the_spa_fallback_turns_both_s3_denial_codes_into_the_shell" {
  command = plan

  assert {
    condition     = length(aws_cloudfront_distribution.this.custom_error_response) == 2
    error_message = "Both 403 and 404 must be mapped by default. A private bucket returns 403 rather than 404 for a missing key, so mapping only 404 leaves every deep link in a SPA broken."
  }

  assert {
    condition = alltrue([
      for r in aws_cloudfront_distribution.this.custom_error_response : r.response_code == 200
    ])
    error_message = "The fallback must answer 200: a client-side router only runs if the browser treats the shell as a successful page load."
  }

  assert {
    condition = alltrue([
      for r in aws_cloudfront_distribution.this.custom_error_response : r.response_page_path == "/index.html"
    ])
    error_message = "The fallback must serve /<default_root_object> with a leading slash, which is the form CloudFront requires for response_page_path."
  }

  assert {
    condition = alltrue([
      for r in aws_cloudfront_distribution.this.custom_error_response : r.error_caching_min_ttl == 0
    ])
    error_message = "error_caching_min_ttl must default to zero so a newly deployed route stops 404ing as soon as it is uploaded rather than after a cached error expires."
  }
}

run "a_custom_root_object_and_error_caching_ttl_follow_through_to_the_fallback" {
  command = plan

  variables {
    default_root_object      = "app.html"
    error_caching_min_ttl    = 10
    spa_fallback_error_codes = [404]
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_root_object == "app.html"
    error_message = "default_root_object must reach the distribution, since it is the object the bare root URL serves."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.custom_error_response).response_page_path == "/app.html"
    error_message = "The fallback path must be derived from default_root_object rather than hardcoded to index.html, otherwise a site whose shell has another name falls back to an object that does not exist."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.custom_error_response).error_caching_min_ttl == 10
    error_message = "Portfolio sets error_caching_min_ttl to 10 to take some load off the origin during a deploy, so the input must reach every mapped code."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.custom_error_response) == 1
    error_message = "spa_fallback_error_codes must replace the default pair rather than extend it, so a consumer whose bucket allows ListBucket can map 404 alone."
  }
}

run "an_unknown_cache_mode_is_rejected" {
  command = plan

  variables {
    cache_mode = "legacy"
  }

  expect_failures = [var.cache_mode]
}

run "the_policy_model_with_no_cache_policy_is_rejected" {
  command = plan

  variables {
    cache_policy_id = null
  }

  expect_failures = [var.cache_policy_id]
}

run "an_unsupported_cookies_forward_value_is_rejected" {
  command = plan

  variables {
    forwarded_values = {
      cookies_forward = "some"
    }
  }

  expect_failures = [var.forwarded_values]
}

run "ttls_out_of_order_are_rejected" {
  command = plan

  variables {
    forwarded_values = {
      min_ttl     = 600
      default_ttl = 300
      max_ttl     = 60
    }
  }

  expect_failures = [var.forwarded_values]
}

run "an_error_code_cloudfront_cannot_map_is_rejected" {
  command = plan

  variables {
    spa_fallback_error_codes = [403, 418]
  }

  expect_failures = [var.spa_fallback_error_codes]
}

run "a_negative_error_caching_ttl_is_rejected" {
  command = plan

  variables {
    error_caching_min_ttl = -1
  }

  expect_failures = [var.error_caching_min_ttl]
}

run "a_root_object_with_a_leading_slash_is_rejected" {
  command = plan

  variables {
    default_root_object = "/index.html"
  }

  expect_failures = [var.default_root_object]
}
