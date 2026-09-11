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

  # The identity settings that stay in the environment. Every one of these is a short scalar whose
  # length does not grow with the consumer's configuration, which is the rule this map follows: see
  # identity_jwt_config_json below for the two values that broke it.
  #
  # Merged in only when there is something to enforce, so a consumer that leaves both inputs alone
  # sees no change to the function at all.
  identity_jwt_environment = local.identity_jwt_enabled ? {
    IDENTITY_ISSUER   = var.identity_jwt.issuer
    IDENTITY_AUDIENCE = var.identity_jwt.audience

    # Derived from the issuer by default, which is where the identity function publishes it and the
    # same URL the native JWT authorizer reads in production.
    IDENTITY_JWKS_URL = coalesce(var.identity_jwt.jwks_url, "${var.identity_jwt.issuer}/.well-known/jwks.json")

    IDENTITY_JWKS_TTL_SECONDS   = tostring(coalesce(var.identity_jwt.jwks_ttl_seconds, 300))
    IDENTITY_CLOCK_SKEW_SECONDS = tostring(coalesce(var.identity_jwt.clock_skew_seconds, 60))
  } : {}

  # The whole environment the authorizer function gets, named here rather than inline in the
  # resource so the test suite can assert its serialised size against Lambda's 4096 byte cap without
  # planning a real function.
  #
  # A Lambda's environment limit is measured over the whole map, keys and values together, and only
  # at UpdateFunctionConfiguration. Terraform's plan cannot see it, so an oversized map is a green
  # plan and a failed apply. Nothing in this map is allowed to scale with the number of routes, the
  # number of hosts or the size of a key.
  authorizer_environment = merge({
    HEADER_NAME         = lower(var.origin_verify_header_name)
    ORIGIN_VERIFY_PARAM = aws_ssm_parameter.origin_verify.name
    COOKIE_DOMAIN       = var.cookie_domain
    KEY_PAIR_ID         = aws_cloudfront_public_key.signing.id
    },
    local.identity_jwt_environment,
  )

  # The two values that cannot live in the environment, rendered into the authorizer's deployment
  # package as identity_jwt_config.json and read by the handler at import time.
  #
  #   route_keys  the full enforced route key list. At 95 keys this serialised to 3600 bytes, which
  #               with the other variables put the environment at 4545 bytes and made every apply
  #               fail. It cannot be shortened: a key missing from the list is a route that is not
  #               enforced, and prefix matching is unsafe because anonymous guard routes sit under
  #               the same prefixes as enforced ones.
  #   signing_public_key_pem
  #               the public half of the CloudFront signing key pair, 451 bytes. Not a secret:
  #               CloudFront publishes it and it only verifies signatures. It moved for size alone.
  #
  # Written even when nothing is enforced, with an empty route key list, so the package has the same
  # shape in both states and the handler has one code path. jsonencode sorts object keys, and the
  # route key list is sorted above, so the rendered bytes are stable across plans.
  #   anonymous_path_prefixes
  #               the paths the authorizer admits with no credential at all. See
  #               local.identity_anonymous_path_prefixes below for why the key material belongs
  #               here.
  identity_jwt_config_json = jsonencode({
    route_keys              = local.identity_jwt_enabled ? local.identity_jwt_route_keys : []
    signing_public_key_pem  = tls_private_key.signing.public_key_pem
    anonymous_path_prefixes = local.identity_anonymous_path_prefixes
  })

  # The paths admitted with no gate credential and no token.
  #
  # THE DEFECT THIS FIXES. The authorizer verifies an identity token against the issuer's JWKS,
  # which it fetches over HTTPS. In the gate topology the issuer is the same API the authorizer
  # guards, so that fetch goes straight back through this authorizer carrying none of a browser's
  # credentials, is refused 403, and every identity token is denied with "JWKS unavailable". No
  # authenticated request can succeed. The authorizer now presents the origin verification header on
  # that fetch, which closes the loop on its own; these prefixes are the other half, because the
  # discovery document and the JWKS are public key material that every other verifier of these
  # tokens needs to reach without a credential too.
  #
  # Defaulted from the issuer rather than hardcoded, so it follows a consumer that mounts identity
  # somewhere other than /api/auth. Only the `.well-known` subtree is opened: it holds the discovery
  # document and the key set and nothing else. A consumer that wants no hole at all passes [].
  identity_anonymous_path_prefixes = var.identity_anonymous_path_prefixes != null ? var.identity_anonymous_path_prefixes : (
    local.identity_jwt_enabled ? ["${local.identity_issuer_path}/.well-known/"] : []
  )

  # The path component of the issuer, which is the prefix the identity routes are mounted under.
  # `https://api.example.com/api/auth` gives `/api/auth`, and an issuer with no path at all gives
  # the empty string, so the rendered prefix is plain `/.well-known/`.
  #
  # Taken by splitting off scheme and host rather than by regex: the host cannot contain a slash, so
  # everything from the third slash on is the path, and that holds for any https URL. The trailing
  # slash is trimmed here and added back where the prefix is built, so an issuer written with or
  # without one renders the same bytes.
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
