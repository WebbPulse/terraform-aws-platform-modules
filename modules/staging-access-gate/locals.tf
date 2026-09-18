locals {
  auth_path_pattern = "${var.auth_path_prefix}*"
  api_path_pattern  = "${var.api_path_prefix}*"

  all_hosts = distinct(concat([var.site_host], var.additional_hosts))

  callback_urls = [for h in local.all_hosts : "https://${h}${var.auth_path_prefix}callback"]
  logout_urls   = [for h in local.all_hosts : "https://${h}${var.auth_path_prefix}logged-out"]

  region = data.aws_region.current.region

  hosted_ui_domain = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${local.region}.amazoncognito.com"

  ssm_prefix = "/${var.name}/access-gate"

  login_permission_source_arn = coalesce(var.cloudfront_distribution_arn, "arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*")

  invite_login_url = coalesce(var.invite_login_url, "https://${var.site_host}/")

  login_origin_domain_name = trimsuffix(trimprefix(aws_lambda_function_url.login.function_url, "https://"), "/")

  cache_policy_caching_disabled                = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  origin_request_policy_all_viewer_except_host = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

  default_app_handler = "function appHandler(event) { return event.request; }"

  http_api_attached = var.http_api_attached != null ? var.http_api_attached : var.http_api_id != null

  identity_jwt_enabled = var.identity_jwt != null && length(var.identity_jwt_route_keys) > 0

  identity_jwt_route_keys = sort(var.identity_jwt_route_keys)

  identity_jwt_environment = local.identity_jwt_enabled ? {
    IDENTITY_ISSUER   = var.identity_jwt.issuer
    IDENTITY_AUDIENCE = var.identity_jwt.audience

    IDENTITY_JWKS_URL = coalesce(var.identity_jwt.jwks_url, "${var.identity_jwt.issuer}/.well-known/jwks.json")

    IDENTITY_JWKS_TTL_SECONDS   = tostring(coalesce(var.identity_jwt.jwks_ttl_seconds, 300))
    IDENTITY_CLOCK_SKEW_SECONDS = tostring(coalesce(var.identity_jwt.clock_skew_seconds, 60))
  } : {}

  authorizer_environment = merge({
    HEADER_NAME         = lower(var.origin_verify_header_name)
    ORIGIN_VERIFY_PARAM = aws_ssm_parameter.origin_verify.name
    COOKIE_DOMAIN       = var.cookie_domain
    KEY_PAIR_ID         = aws_cloudfront_public_key.signing.id
    },
    local.identity_jwt_environment,
  )

  identity_jwt_config_json = jsonencode({
    route_keys              = local.identity_jwt_enabled ? local.identity_jwt_route_keys : []
    signing_public_key_pem  = tls_private_key.signing.public_key_pem
    anonymous_path_prefixes = local.identity_anonymous_path_prefixes
  })

  identity_anonymous_path_prefixes = var.identity_anonymous_path_prefixes != null ? var.identity_anonymous_path_prefixes : (
    local.identity_jwt_enabled ? ["${local.identity_issuer_path}/.well-known/"] : []
  )

  identity_issuer_host_and_path = local.identity_jwt_enabled ? trimprefix(var.identity_jwt.issuer, "https://") : ""
  identity_issuer_path_segments = compact(slice(
    split("/", local.identity_issuer_host_and_path),
    1,
    length(split("/", local.identity_issuer_host_and_path)),
  ))
  identity_issuer_path = length(local.identity_issuer_path_segments) > 0 ? "/${join("/", local.identity_issuer_path_segments)}" : ""
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}
