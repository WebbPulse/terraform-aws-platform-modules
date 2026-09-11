locals {
  count = var.enabled ? 1 : 0

  validation_records = {
    for dvo in(var.enabled ? aws_acm_certificate.this[0].domain_validation_options : []) : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
}
