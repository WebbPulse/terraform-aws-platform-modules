locals {
  viewer_request_function_enabled = var.viewer_request_function != null

  viewer_request_canonical_host = (
    local.viewer_request_function_enabled ? var.viewer_request_function.canonical_host : "apex"
  )

  viewer_request_canonical_host_name = (
    local.viewer_request_canonical_host == "www"
    ? "www.${try(var.viewer_request_function.domain, "")}"
    : try(var.viewer_request_function.domain, "")
  )

  viewer_request_redirect_from_host = (
    local.viewer_request_canonical_host == "www"
    ? try(var.viewer_request_function.domain, "")
    : "www.${try(var.viewer_request_function.domain, "")}"
  )

  viewer_request_redirect_description = (
    local.viewer_request_canonical_host == "www"
    ? "Apex to www 301 redirect. Keeps www.${try(var.viewer_request_function.domain, "")} canonical."
    : "www to apex 301 redirect. Keeps ${try(var.viewer_request_function.domain, "")} canonical."
  )

  viewer_request_handler_js = (
    !local.viewer_request_function_enabled ? null :
    local.viewer_request_canonical_host == "none"
    ? templatefile("${path.module}/viewer_request/app_handler_no_redirect.js.tftpl", {})
    : templatefile("${path.module}/viewer_request/app_handler.js.tftpl", {
      canonical_host_name  = local.viewer_request_canonical_host_name
      redirect_from_host   = local.viewer_request_redirect_from_host
      redirect_description = local.viewer_request_redirect_description
    })
  )

  viewer_request_function_code = local.viewer_request_function_enabled ? templatefile(
    "${path.module}/viewer_request/uri_rewrite.js.tftpl",
    { app_handler = local.viewer_request_handler_js }
  ) : null

  viewer_request_function_name = (
    local.viewer_request_function_enabled
    ? coalesce(var.viewer_request_function.name, "${var.name}-uri-rewrite")
    : null
  )

  viewer_request_function_comment = (
    local.viewer_request_function_enabled
    ? coalesce(
      var.viewer_request_function.comment,
      local.viewer_request_canonical_host == "none"
      ? "Rewrite extensionless paths to index.html."
      : "${local.viewer_request_redirect_description} Rewrites extensionless paths to index.html."
    )
    : null
  )
}

resource "aws_cloudfront_function" "viewer_request" {
  count = local.viewer_request_function_enabled && !local.gate_enabled ? 1 : 0

  name    = local.viewer_request_function_name
  runtime = var.viewer_request_function.runtime
  comment = local.viewer_request_function_comment
  publish = var.viewer_request_function.publish
  code    = local.viewer_request_function_code

  lifecycle {
    precondition {
      condition     = var.viewer_request_function_arn == null
      error_message = "Set either viewer_request_function or viewer_request_function_arn, not both."
    }
  }
}
