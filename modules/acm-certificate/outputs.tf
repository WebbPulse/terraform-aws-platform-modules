output "certificate_arn" {
  description = "ARN of the issued certificate, available only once ACM has validated it. Pass this to CloudFront or an API Gateway domain rather than the certificate's own arn, so the consumer waits for issuance."
  value       = var.enabled ? aws_acm_certificate_validation.this[0].certificate_arn : null
}

output "domain_validation_options" {
  description = "What ACM asked to have proven: one entry per covered domain, each with resource_record_name, resource_record_type and resource_record_value. Empty when enabled is false."
  value       = var.enabled ? aws_acm_certificate.this[0].domain_validation_options : []
}

output "validation_record_fqdns" {
  description = "FQDNs of the validation records this module wrote, the same set handed to the validation resource."
  value       = [for r in aws_route53_record.validation : r.fqdn]
}
