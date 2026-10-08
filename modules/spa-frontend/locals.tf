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
  index_response_headers_policy_id = try(
    coalesce(try(var.index_cache_policies.response_headers_policy_id, null), local.response_headers_policy_id),
    null,
  )

  security_headers_create = var.response_headers_policy_id == null && var.security_headers.enabled
  security_headers_name   = coalesce(var.security_headers.name, "${var.name}-security-headers")

  response_headers_policy_id = (
    var.response_headers_policy_id != null ? var.response_headers_policy_id :
    local.security_headers_create ? aws_cloudfront_response_headers_policy.security[0].id :
    null
  )

  csp_mode    = var.security_headers.content_security_policy.mode
  csp_sources = var.security_headers.content_security_policy

  content_security_policy = join("; ", compact([
    "default-src 'self'",
    join(" ", concat(["connect-src", "'self'"], local.csp_sources.connect_src)),
    join(" ", concat(["img-src", "'self'", "data:"], local.csp_sources.img_src)),
    join(" ", concat(["script-src", "'self'"], local.csp_sources.script_src)),
    join(" ", concat(["style-src", "'self'", "'unsafe-inline'"], local.csp_sources.style_src)),
    join(" ", concat(["font-src", "'self'", "data:"], local.csp_sources.font_src)),
    length(local.csp_sources.frame_src) > 0 ? join(" ", concat(["frame-src", "'self'"], local.csp_sources.frame_src)) : null,
    length(local.csp_sources.media_src) > 0 ? join(" ", concat(["media-src", "'self'"], local.csp_sources.media_src)) : null,
    length(local.csp_sources.worker_src) > 0 ? join(" ", concat(["worker-src", "'self'"], local.csp_sources.worker_src)) : null,
    "object-src 'none'",
    "base-uri 'self'",
    "form-action ${join(" ", concat(["'self'"], local.csp_sources.form_action))}",
    "frame-ancestors 'none'",
    local.csp_sources.report_uri != null ? "report-uri ${local.csp_sources.report_uri}" : null,
  ]))

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
