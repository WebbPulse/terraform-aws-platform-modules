variables {
  domain_name = "example-staging.com"
  zone_id     = "Z0EXAMPLESTAGING01"
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

provider "aws" {
  alias                       = "records"
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "the_arn_a_consumer_uses_comes_from_the_validation_resource_not_the_certificate" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.this
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-1111-1111-1111-111111111111"
    }
  }

  override_resource {
    target          = aws_acm_certificate_validation.this
    override_during = plan
    values = {
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-1111-1111-1111-111111111111"
    }
  }

  assert {
    condition     = output.certificate_arn == aws_acm_certificate_validation.this[0].certificate_arn
    error_message = "certificate_arn must be read off the validation resource: taking it from the certificate would let CloudFront or an API Gateway domain attach an ARN that ACM has not issued yet, which fails the apply with an unhelpful error far from the cause."
  }
}

run "the_validation_record_fqdns_output_matches_the_records_the_module_wrote" {
  command = plan

  assert {
    condition     = length(output.validation_record_fqdns) == length(aws_route53_record.validation)
    error_message = "validation_record_fqdns must list one FQDN per record actually written, since it is the same set handed to the validation resource and a shorter list would let the wait pass before every record exists."
  }

  assert {
    condition     = length(output.domain_validation_options) == length(local.validation_records)
    error_message = "domain_validation_options must expose one entry per covered domain, which is the same set the module keys its records by, so a consumer writing its own records in a zone this module cannot reach has the record name, type and value it needs."
  }
}

run "every_output_is_safe_to_read_when_the_module_is_disabled" {
  command = plan

  variables {
    enabled = false
    zone_id = null
  }

  assert {
    condition     = output.certificate_arn == null
    error_message = "certificate_arn must be null rather than an error when disabled: both consumers hand it straight to a CloudFront viewer certificate or an API Gateway domain in every environment, including ones that serve no custom domain."
  }

  assert {
    condition     = output.domain_validation_options == []
    error_message = "domain_validation_options must be an empty list rather than null when disabled, so a consumer iterating it with for_each gets an empty set instead of a type error."
  }

  assert {
    condition     = output.validation_record_fqdns == []
    error_message = "validation_record_fqdns must be an empty list when disabled, since nothing was written and a caller counting it should see zero."
  }
}

run "a_wildcard_domain_name_is_accepted" {
  command = plan

  variables {
    domain_name = "*.example-staging.com"
  }

  assert {
    condition     = aws_acm_certificate.this[0].domain_name == "*.example-staging.com"
    error_message = "A wildcard must be a legal primary domain: a certificate issued for *.example-staging.com alone is what covers every subdomain without naming each one, and the validation regex must not reject it."
  }
}

run "a_subdomain_domain_name_is_accepted" {
  command = plan

  variables {
    domain_name = "api.example-staging.com"
  }

  assert {
    condition     = aws_acm_certificate.this[0].domain_name == "api.example-staging.com"
    error_message = "Both consumers issue a separate regional certificate for their api host, so a multi-label subdomain must pass the domain_name validation."
  }
}

run "a_single_label_domain_name_is_rejected" {
  command = plan

  variables {
    domain_name = "example"
  }

  expect_failures = [var.domain_name]
}

run "an_uppercase_domain_name_is_rejected" {
  command = plan

  variables {
    domain_name = "Example-Staging.com"
  }

  expect_failures = [var.domain_name]
}

run "a_domain_name_with_a_trailing_dot_is_rejected" {
  command = plan

  variables {
    domain_name = "example-staging.com."
  }

  expect_failures = [var.domain_name]
}

run "a_domain_name_with_a_scheme_or_path_is_rejected" {
  command = plan

  variables {
    domain_name = "https://example-staging.com"
  }

  expect_failures = [var.domain_name]
}

run "an_enabled_module_with_no_zone_id_is_rejected" {
  command = plan

  variables {
    enabled = true
    zone_id = null
  }

  expect_failures = [var.zone_id]
}

run "a_negative_validation_record_ttl_is_rejected" {
  command = plan

  variables {
    validation_record_ttl = -1
  }

  expect_failures = [var.validation_record_ttl]
}

run "a_validation_record_ttl_beyond_the_route53_ceiling_is_rejected" {
  command = plan

  variables {
    validation_record_ttl = 2147483648
  }

  expect_failures = [var.validation_record_ttl]
}
