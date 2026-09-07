resource "aws_cloudfront_public_key" "signing" {
  name        = "${var.name}-access-gate"
  comment     = "Verifies the signed cookies the ${var.name} access gate issues."
  encoded_key = tls_private_key.signing.public_key_pem
}

resource "aws_cloudfront_key_group" "signing" {
  name    = "${var.name}-access-gate"
  comment = "Trusted key group for the ${var.name} access gate. Attach to every behavior that must require a session."
  items   = [aws_cloudfront_public_key.signing.id]
}

resource "aws_cloudfront_origin_access_control" "login" {
  name                              = "${var.name}-access-gate-login"
  description                       = "SigV4-signs CloudFront requests to the ${var.name} access gate login function URL."
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "gate" {
  name    = "${var.name}-access-gate"
  runtime = "cloudfront-js-2.0"
  comment = "Sends viewers without a live access gate session to ${var.auth_path_prefix}login; runs the application handler first."
  publish = true

  code = templatefile("${path.module}/cloudfront_functions/gate.js.tftpl", {
    app_handler = var.viewer_request_handler_js == "" ? local.default_app_handler : var.viewer_request_handler_js
    auth_prefix = var.auth_path_prefix
    api_prefix  = var.api_path_prefix
  })
}
