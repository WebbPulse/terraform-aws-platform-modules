# Minimal consumer: an existing S3-backed SPA distribution and an existing HTTP API with a custom
# domain, both moved behind the gate. The SPA calls https://api.staging.example.com directly, the
# way it does in production; the gate's authorizer verifies the same signed cookies the browser
# already holds, so the API never has to be proxied through CloudFront. Real consumers gate every
# block below on a variable so the production plan is a no-op; see the module README.

module "gate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-access-gate"
  version = "~> 1.0"

  name           = "example-staging"
  cookie_domain  = "staging.example.com"
  site_host      = "www.staging.example.com"
  allowed_emails = ["someone@example.com"]

  # cloudfront_distribution_arn is left unset on purpose: the distribution below consumes this
  # module's outputs, so naming it here would be a cycle. The invoke permission then covers any
  # distribution in the account.
  http_api_id = aws_apigatewayv2_api.api.id

  viewer_request_handler_js = file("${path.module}/app_handler.js")
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = ["www.staging.example.com"]

  # The SPA's own origin. A real consumer already has this bucket and an origin access
  # control on it; only the gate specific blocks below are new.
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

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

  # SPA fallback: CloudFront serves the app shell for client side routes.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # A real consumer points this at the ACM certificate covering the alias above, issued in
  # us-east-1. The default certificate keeps this example free of cross region plumbing.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket" "frontend" {
  bucket = "example-staging-frontend"
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "example-staging-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_apigatewayv2_api" "api" {
  name                         = "example-staging-api"
  protocol_type                = "HTTP"
  disable_execute_api_endpoint = true

  # The browser calls this API from the SPA host, so the origin must be listed explicitly and
  # credentials allowed; a wildcard origin is not permitted alongside credentials. The gate's
  # authorizer lets OPTIONS through so this preflight answer is the one the browser sees.
  cors_configuration {
    allow_origins     = ["https://www.staging.example.com"]
    allow_methods     = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_headers     = ["content-type", "authorization"]
    allow_credentials = true
    max_age           = 300
  }
}

# The application Lambda behind the API, and the integration the route below targets. A real
# consumer already has these, usually from the lambda-function module.
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_lambda_function" "api" {
  function_name = "example-staging-api"
  role          = aws_iam_role.api.arn
  runtime       = "python3.13"
  handler       = "app.handler"
  filename      = "app.zip"
}

resource "aws_iam_role" "api" {
  name = "example-staging-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Every route carries the gate authorizer. It admits CORS preflights, the origin verification
# header (for pipelines and health checks, value in module.gate.origin_verify_ssm_parameter_name),
# and the gate's own signed cookies, which the browser sends because they are scoped to
# Domain=staging.example.com.
resource "aws_apigatewayv2_route" "default" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "$default"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = module.gate.http_api_authorizer_id
}
