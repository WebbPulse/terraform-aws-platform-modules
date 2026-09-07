locals {
  bucket_name                = coalesce(var.bucket_name, var.name)
  origin_access_control_name = coalesce(var.origin_access_control_name, var.name)

  custom_domain = length(var.aliases) > 0
  use_policies  = var.cache_mode == "policies"
  gate_enabled  = var.access_gate != null

  # The gate's function wraps the application's own viewer-request logic, so it replaces it.
  viewer_request_function_arn = local.gate_enabled ? var.access_gate.viewer_request_function_arn : var.viewer_request_function_arn

  spa_shell_path = "/${var.default_root_object}"

  frontend_url = local.custom_domain ? "https://${var.aliases[0]}" : "https://${aws_cloudfront_distribution.this.domain_name}"

  dns_records_a    = var.create_dns_records ? var.dns_records : {}
  dns_records_aaaa = var.create_dns_records && var.create_aaaa_records ? var.dns_records : {}

  distribution_tags = merge(var.tags, var.distribution_tags)
}
