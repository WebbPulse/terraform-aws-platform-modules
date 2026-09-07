# One distribution in front of the bucket. Everything that varies between consumers is a variable
# so that an existing hand-written distribution can be moved here without a replacement.

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = var.ipv6_enabled
  comment             = var.comment
  default_root_object = var.default_root_object
  aliases             = var.aliases
  price_class         = var.price_class

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = var.origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  # Login Lambda function URL, only with an access gate.
  dynamic "origin" {
    for_each = local.gate_enabled ? [1] : []

    content {
      domain_name              = var.access_gate.login_origin_domain_name
      origin_id                = var.access_gate.login_origin_id
      origin_access_control_id = var.access_gate.login_origin_access_control_id

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  # API host with the origin verification header, only with an access gate.
  dynamic "origin" {
    for_each = local.gate_enabled ? [1] : []

    content {
      domain_name = var.access_gate.api_origin_domain_name
      origin_id   = var.access_gate.api_origin_id

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }

      custom_header {
        name  = var.access_gate.origin_verify_header_name
        value = var.access_gate.origin_verify_header_value
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = var.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = local.use_policies ? var.cache_policy_id : null
    origin_request_policy_id   = local.use_policies ? var.origin_request_policy_id : null
    response_headers_policy_id = local.use_policies ? var.response_headers_policy_id : null

    dynamic "forwarded_values" {
      for_each = local.use_policies ? [] : [var.forwarded_values]

      content {
        query_string = forwarded_values.value.query_string
        headers      = forwarded_values.value.headers

        cookies {
          forward = forwarded_values.value.cookies_forward
        }
      }
    }

    min_ttl     = local.use_policies ? null : var.forwarded_values.min_ttl
    default_ttl = local.use_policies ? null : var.forwarded_values.default_ttl
    max_ttl     = local.use_policies ? null : var.forwarded_values.max_ttl

    trusted_key_groups = local.gate_enabled ? [var.access_gate.key_group_id] : null

    dynamic "function_association" {
      for_each = local.viewer_request_function_arn == null ? [] : [local.viewer_request_function_arn]

      content {
        event_type   = "viewer-request"
        function_arn = function_association.value
      }
    }
  }

  # Ordered behaviors exist only with an access gate. Their order matters: CloudFront evaluates
  # path patterns top to bottom.

  dynamic "ordered_cache_behavior" {
    for_each = local.gate_enabled ? [1] : []

    content {
      path_pattern             = var.access_gate.auth_path_pattern
      target_origin_id         = var.access_gate.login_origin_id
      viewer_protocol_policy   = "https-only"
      allowed_methods          = ["GET", "HEAD", "OPTIONS"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = var.access_gate.cache_policy_id_caching_disabled
      origin_request_policy_id = var.access_gate.origin_request_policy_id_all_viewer_except_host_header

      function_association {
        event_type   = "viewer-request"
        function_arn = var.access_gate.viewer_request_function_arn
      }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.gate_enabled ? [1] : []

    content {
      path_pattern             = var.access_gate.api_path_pattern
      target_origin_id         = var.access_gate.api_origin_id
      viewer_protocol_policy   = "https-only"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = var.access_gate.cache_policy_id_caching_disabled
      origin_request_policy_id = var.access_gate.origin_request_policy_id_all_viewer_except_host_header
      trusted_key_groups       = [var.access_gate.key_group_id]

      function_association {
        event_type   = "viewer-request"
        function_arn = var.access_gate.viewer_request_function_arn
      }
    }
  }

  # The SPA shell must stay reachable without signed cookies, because CloudFront's own
  # custom_error_response fetch carries none. The gate function still turns away browsers that
  # ask for it directly without a session. Caching mirrors the default behavior.
  dynamic "ordered_cache_behavior" {
    for_each = local.gate_enabled ? [1] : []

    content {
      path_pattern           = local.spa_shell_path
      target_origin_id       = var.origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id            = local.use_policies ? var.cache_policy_id : null
      origin_request_policy_id   = local.use_policies ? var.origin_request_policy_id : null
      response_headers_policy_id = local.use_policies ? var.response_headers_policy_id : null

      dynamic "forwarded_values" {
        for_each = local.use_policies ? [] : [var.forwarded_values]

        content {
          query_string = forwarded_values.value.query_string
          headers      = forwarded_values.value.headers

          cookies {
            forward = forwarded_values.value.cookies_forward
          }
        }
      }

      min_ttl     = local.use_policies ? null : var.forwarded_values.min_ttl
      default_ttl = local.use_policies ? null : var.forwarded_values.default_ttl
      max_ttl     = local.use_policies ? null : var.forwarded_values.max_ttl

      function_association {
        event_type   = "viewer-request"
        function_arn = var.access_gate.viewer_request_function_arn
      }
    }
  }

  # Client-side routing: S3 misses come back as the SPA shell with a 200.
  dynamic "custom_error_response" {
    for_each = toset(var.spa_fallback_error_codes)

    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = local.spa_shell_path
      error_caching_min_ttl = var.error_caching_min_ttl
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.custom_domain ? null : true
    acm_certificate_arn            = local.custom_domain ? var.acm_certificate_arn : null
    ssl_support_method             = local.custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.custom_domain ? var.minimum_protocol_version : null
  }

  tags = local.distribution_tags
}
