locals {
  auth_path_pattern = "${var.auth_path_prefix}*"
  api_path_pattern  = "${var.api_path_prefix}*"

  all_hosts = distinct(concat([var.site_host], var.additional_hosts))

  callback_urls = [for h in local.all_hosts : "https://${h}${var.auth_path_prefix}callback"]
  logout_urls   = [for h in local.all_hosts : "https://${h}${var.auth_path_prefix}logged-out"]

  # AWS provider 6.x exposes the region as `region`; 5.x only has `name` and `id`. A schema-level
  # unknown attribute is a static error that try() cannot catch, so `id` is the one spelling that
  # resolves on both majors (6.x only warns about it).
  region = data.aws_region.current.id

  hosted_ui_domain = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${local.region}.amazoncognito.com"

  ssm_prefix = "/${var.name}/access-gate"

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
