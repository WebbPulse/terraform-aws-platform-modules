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
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}
