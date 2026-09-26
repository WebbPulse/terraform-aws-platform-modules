locals {
  bucket_name                = coalesce(var.bucket_name, var.name)
  origin_access_control_name = coalesce(var.origin_access_control_name, var.name)

  custom_domain = length(var.aliases) > 0
  use_policies  = var.cache_mode == "policies"
  gate_enabled  = var.access_gate != null

  gate_api_proxy_enabled = local.gate_enabled && var.access_gate.api_origin_domain_name != null

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

  viewer_request_function_arn = (
    local.gate_enabled ? var.access_gate.viewer_request_function_arn :
    var.viewer_request_function != null ? aws_cloudfront_function.viewer_request[0].arn :
    var.viewer_request_function_arn
  )

  spa_shell_path = "/${var.default_root_object}"

  gate_session_required_path = local.gate_enabled ? coalesce(
    var.access_gate.session_required_path,
    "${trimsuffix(var.access_gate.auth_path_pattern, "*")}session-required",
  ) : null

  spa_fallback_error_codes = local.gate_enabled ? [for c in var.spa_fallback_error_codes : c if c != 403] : var.spa_fallback_error_codes

  frontend_url = local.custom_domain ? "https://${var.aliases[0]}" : "https://${aws_cloudfront_distribution.this.domain_name}"

  dns_records_a    = var.create_dns_records ? var.dns_records : {}
  dns_records_aaaa = var.create_dns_records && var.create_aaaa_records ? var.dns_records : {}

  distribution_tags = merge(var.tags, var.distribution_tags)
}
