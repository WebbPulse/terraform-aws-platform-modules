locals {
  count = var.enabled ? 1 : 0

  # Every domain ACM asks to be proven, keyed by the domain it belongs to. A certificate that
  # covers an apex and its wildcard gets two entries here holding the same record, because ACM
  # proves both with one CNAME; both are kept so the key set matches one record per covered
  # domain.
  validation_records = {
    for dvo in(var.enabled ? aws_acm_certificate.this[0].domain_validation_options : []) : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
}
