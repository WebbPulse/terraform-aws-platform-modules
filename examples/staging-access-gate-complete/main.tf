# Minimal consumer: an existing S3-backed SPA distribution and an existing HTTP API with a custom
# domain, both moved behind the gate. Real consumers gate every block below on a variable so the
# production plan is a no-op; see the module README.

module "gate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-access-gate"
  version = "~> 1.0"

  name           = "example-staging"
  cookie_domain  = "staging.example.com"
  site_host      = "www.staging.example.com"
  allowed_emails = ["someone@example.com"]

  cloudfront_distribution_arn = aws_cloudfront_distribution.frontend.arn
  http_api_id                 = aws_apigatewayv2_api.api.id

  viewer_request_handler_js = file("${path.module}/app_handler.js")
}

resource "aws_cloudfront_distribution" "frontend" {
  # ... existing S3 origin, aliases, certificate ...

  origin {
    domain_name              = module.gate.login_origin_domain_name
    origin_id                = "access-gate-login"
    origin_access_control_id = module.gate.login_origin_access_control_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    domain_name = "api.staging.example.com"
    origin_id   = "api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = module.gate.origin_verify_header_name
      value = module.gate.origin_verify_header_value
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    trusted_key_groups     = [module.gate.key_group_id]

    function_association {
      event_type   = "viewer-request"
      function_arn = module.gate.viewer_request_function_arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = module.gate.auth_path_pattern
    target_origin_id         = "access-gate-login"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = module.gate.cache_policy_id_caching_disabled
    origin_request_policy_id = module.gate.origin_request_policy_id_all_viewer_except_host_header

    function_association {
      event_type   = "viewer-request"
      function_arn = module.gate.viewer_request_function_arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = module.gate.api_path_pattern
    target_origin_id         = "api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = module.gate.cache_policy_id_caching_disabled
    origin_request_policy_id = module.gate.origin_request_policy_id_all_viewer_except_host_header
    trusted_key_groups       = [module.gate.key_group_id]

    function_association {
      event_type   = "viewer-request"
      function_arn = module.gate.viewer_request_function_arn
    }
  }

  # The SPA fallback page must be reachable by CloudFront's own custom_error_response fetch, which
  # carries no cookies; the gate function still turns away browsers that ask for it directly.
  ordered_cache_behavior {
    path_pattern           = "/index.html"
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    function_association {
      event_type   = "viewer-request"
      function_arn = module.gate.viewer_request_function_arn
    }
  }

  # ... custom_error_response 403/404 -> /index.html, restrictions, viewer_certificate ...
}

resource "aws_apigatewayv2_api" "api" {
  name                         = "example-staging-api"
  protocol_type                = "HTTP"
  disable_execute_api_endpoint = true
}

resource "aws_apigatewayv2_route" "default" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "$default"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = module.gate.http_api_authorizer_id
}
