resource "aws_cloudfront_response_headers_policy" "security" {
  count = local.security_headers_create ? 1 : 0

  name    = local.security_headers_name
  comment = "Security headers for ${var.name}"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = var.security_headers.hsts_max_age_seconds
      include_subdomains         = var.security_headers.hsts_include_subdomains
      preload                    = var.security_headers.hsts_preload
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    dynamic "content_security_policy" {
      for_each = local.csp_mode == "enforce" ? [local.content_security_policy] : []

      content {
        content_security_policy = content_security_policy.value
        override                = true
      }
    }
  }

  dynamic "custom_headers_config" {
    for_each = local.csp_mode == "report_only" ? [local.content_security_policy] : []

    content {
      items {
        header   = "Content-Security-Policy-Report-Only"
        value    = custom_headers_config.value
        override = true
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.csp_mode == "off" || length(local.content_security_policy) <= 1783
      error_message = "The rendered Content-Security-Policy is longer than the 1783 characters CloudFront accepts in a response headers policy; trim security_headers.content_security_policy sources, for example with a wildcard host."
    }
  }
}
