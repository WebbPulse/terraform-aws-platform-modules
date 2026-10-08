output "bucket_name" {
  description = "Name of the S3 bucket that holds the built site; deploy pipelines sync into it."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN of the S3 bucket, for IAM policies on deploy roles."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the bucket, as used for the S3 origin."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "distribution_id" {
  description = "CloudFront distribution id; deploy pipelines invalidate it."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN, for IAM policies on deploy roles and for a staging-access-gate cloudfront_distribution_arn when no cycle results."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "The distribution's own hostname, for alias records the consumer creates itself."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "Route 53 hosted zone id to use in alias records that point at the distribution."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "origin_access_control_id" {
  description = "Id of the origin access control that signs requests to the bucket."
  value       = aws_cloudfront_origin_access_control.this.id
}

output "origin_id" {
  description = "origin_id of the S3 origin inside the distribution."
  value       = var.origin_id
}

output "frontend_url" {
  description = "Public URL of the site: https:// plus the first alias, or the CloudFront hostname without aliases."
  value       = local.frontend_url
}

output "viewer_request_function_arn" {
  description = "ARN of the viewer-request function in force on the default behavior: the one this module built from viewer_request_function, the one passed in, or the gate's when access_gate is set."
  value       = local.viewer_request_function_arn
}

output "viewer_request_handler_js" {
  description = "The rendered appHandler JavaScript when viewer_request_function is set, for passing to a staging-access-gate as viewer_request_handler_js so the gate wraps it. Null otherwise."
  value       = local.viewer_request_handler_js
}

output "response_headers_policy_id" {
  description = "Id of the response headers policy on the S3 behaviors: response_headers_policy_id when set, otherwise the one this module built from security_headers, or null when security_headers.enabled is false."
  value       = local.response_headers_policy_id
}

output "content_security_policy" {
  description = "The Content-Security-Policy value this module renders from security_headers, and how it is sent: mode is enforce or report_only, and header names the header that carries it. Null when content_security_policy.mode is off, or when the module builds no policy because response_headers_policy_id is set or security_headers.enabled is false."
  value = local.security_headers_create && local.csp_mode != "off" ? {
    mode   = local.csp_mode
    header = local.csp_mode == "enforce" ? "Content-Security-Policy" : "Content-Security-Policy-Report-Only"
    value  = local.content_security_policy
  } : null
}
