locals {
  auth_path_pattern = "${var.auth_path_prefix}*"
  api_path_pattern  = "${var.api_path_prefix}*"

  all_hosts = distinct(concat([var.site_host], var.additional_hosts))

  callback_urls = [for h in local.all_hosts : "https://${h}${var.auth_path_prefix}callback"]
  logout_urls   = [for h in local.all_hosts : "https://${h}${var.auth_path_prefix}logged-out"]

  # `region` is the only spelling the provider does not deprecate: `name` has been deprecated since
  # 6.0 and `id` since 6.47, both with a "will be removed in a future version" warning on every
  # plan. The attribute does not exist at all on 5.x, where reading it is a hard "Unsupported
  # attribute" error rather than something try() can absorb, so this line and the `>= 6.0` floor in
  # versions.tf move together. Do not lower that floor without putting `id` back here.
  region = data.aws_region.current.region

  hosted_ui_domain = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${local.region}.amazoncognito.com"

  ssm_prefix = "/${var.name}/access-gate"

  # Passing the distribution ARN would be a cycle for most consumers (the distribution consumes this
  # module's outputs), so the default scopes the grant to every distribution in the account.
  login_permission_source_arn = coalesce(var.cloudfront_distribution_arn, "arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*")

  invite_login_url = coalesce(var.invite_login_url, "https://${var.site_host}/")

  # Function URLs look like https://<id>.lambda-url.<region>.on.aws/; CloudFront wants the bare host.
  login_origin_domain_name = trimsuffix(trimprefix(aws_lambda_function_url.login.function_url, "https://"), "/")

  # AWS managed policies, listed once so consumers do not copy magic ids around.
  cache_policy_caching_disabled                = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  origin_request_policy_all_viewer_except_host = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

  default_app_handler = "function appHandler(event) { return event.request; }"

  # ---------------------------------------------------------------------------
  # Identity access token enforcement
  # ---------------------------------------------------------------------------

  # Enforcement needs both halves: an issuer and audience to verify against, and at least one route
  # to verify on. Either alone is a no-op, and saying so here rather than in the function keeps the
  # rendered environment honest about whether anything is enforced.
  identity_jwt_enabled = var.identity_jwt != null && length(var.identity_jwt_route_keys) > 0

  # Sorted so the environment variable, and therefore the function's source hash, does not move when
  # a consumer reorders its list. The http-api output is already sorted; this covers a hand written
  # one.
  identity_jwt_route_keys = sort(var.identity_jwt_route_keys)

  # The environment block, merged into the function only when there is something to enforce, so a
  # consumer that leaves both inputs alone sees no change to the function at all.
  identity_jwt_environment = local.identity_jwt_enabled ? {
    IDENTITY_ISSUER   = var.identity_jwt.issuer
    IDENTITY_AUDIENCE = var.identity_jwt.audience

    # Derived from the issuer by default, which is where the identity function publishes it and the
    # same URL the native JWT authorizer reads in production.
    IDENTITY_JWKS_URL = coalesce(var.identity_jwt.jwks_url, "${var.identity_jwt.issuer}/.well-known/jwks.json")

    # One comma separated string because a Lambda environment holds strings. A route key cannot
    # contain a comma, which the variable validates.
    IDENTITY_JWT_ROUTE_KEYS = join(",", local.identity_jwt_route_keys)

    IDENTITY_JWKS_TTL_SECONDS   = tostring(coalesce(var.identity_jwt.jwks_ttl_seconds, 300))
    IDENTITY_CLOCK_SKEW_SECONDS = tostring(coalesce(var.identity_jwt.clock_skew_seconds, 60))
  } : {}
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}
