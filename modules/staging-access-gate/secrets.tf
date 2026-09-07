# The three secrets the gate depends on. All land in SSM SecureString under one prefix so the
# Lambda role can be scoped to exactly that prefix, and so a deploy pipeline that needs the
# origin header (for a health check against the API host) has one well-known place to read it.

resource "tls_private_key" "signing" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "random_password" "origin_verify" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "signing_key" {
  name        = "${local.ssm_prefix}/signing-private-key"
  description = "RSA private key the login Lambda signs CloudFront cookies with. Its public half is aws_cloudfront_public_key ${var.name}-access-gate."
  type        = "SecureString"
  value       = tls_private_key.signing.private_key_pem
  tier        = "Standard"
}

resource "aws_ssm_parameter" "client_secret" {
  name        = "${local.ssm_prefix}/cognito-client-secret"
  description = "Cognito app client secret for the ${var.name} access gate login Lambda."
  type        = "SecureString"
  value       = aws_cognito_user_pool_client.login.client_secret
  tier        = "Standard"
}

resource "aws_ssm_parameter" "origin_verify" {
  name        = "${local.ssm_prefix}/origin-verify"
  description = "Value of the ${var.origin_verify_header_name} header CloudFront adds to API origin requests. The HTTP API authorizer admits only requests carrying it."
  type        = "SecureString"
  value       = random_password.origin_verify.result
  tier        = "Standard"
}
