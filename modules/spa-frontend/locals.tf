locals {
  bucket_name                = coalesce(var.bucket_name, var.name)
  origin_access_control_name = coalesce(var.origin_access_control_name, var.name)

  custom_domain = length(var.aliases) > 0
  use_policies  = var.cache_mode == "policies"
  gate_enabled  = var.access_gate != null

  # The SPA shell behavior follows cache_mode unless index_cache_mode overrides it, and reuses the
  # default behavior's policies unless index_cache_policies overrides them. Both default to the
  # inherited value so a consumer that sets neither plans exactly what it planned before.
  index_cache_mode   = coalesce(var.index_cache_mode, var.cache_mode)
  index_use_policies = local.index_cache_mode == "policies"

  index_cache_policy_id = (
    var.index_cache_policies != null ? var.index_cache_policies.cache_policy_id : var.cache_policy_id
  )
  index_origin_request_policy_id = (
    var.index_cache_policies != null ? var.index_cache_policies.origin_request_policy_id : var.origin_request_policy_id
  )
  index_response_headers_policy_id = (
    var.index_cache_policies != null ? var.index_cache_policies.response_headers_policy_id : var.response_headers_policy_id
  )

  # The gate's function wraps the application's own viewer-request logic, so it replaces it.
  viewer_request_function_arn = local.gate_enabled ? var.access_gate.viewer_request_function_arn : var.viewer_request_function_arn

  spa_shell_path = "/${var.default_root_object}"

  frontend_url = local.custom_domain ? "https://${var.aliases[0]}" : "https://${aws_cloudfront_distribution.this.domain_name}"

  dns_records_a    = var.create_dns_records ? var.dns_records : {}
  dns_records_aaaa = var.create_dns_records && var.create_aaaa_records ? var.dns_records : {}

  distribution_tags = merge(var.tags, var.distribution_tags)
}
