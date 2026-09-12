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

run "the_default_issues_one_dns_validated_certificate_that_waits_for_issuance" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.this
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-1111-1111-1111-111111111111"
    }
  }

  assert {
    condition     = length(aws_acm_certificate.this) == 1
    error_message = "enabled defaults to true, so a consumer passing only domain_name and zone_id must get exactly one certificate."
  }

  assert {
    condition     = aws_acm_certificate.this[0].validation_method == "DNS"
    error_message = "Validation must be DNS and never EMAIL: email validation needs a human to click a link in a mailbox nobody in this estate reads, and it cannot be automated on renewal."
  }

  assert {
    condition     = aws_acm_certificate.this[0].domain_name == "example-staging.com"
    error_message = "domain_name must reach the certificate verbatim: it is the common name ACM issues for, and any rewriting here would issue a certificate for a host nothing serves."
  }

  assert {
    condition     = length(aws_acm_certificate_validation.this) == 1
    error_message = "The validation resource must exist alongside the certificate: it is what makes a consumer wait for ACM to issue before CloudFront or an API Gateway domain tries to serve traffic with the ARN."
  }

  assert {
    condition     = aws_acm_certificate_validation.this[0].certificate_arn == aws_acm_certificate.this[0].arn
    error_message = "The validation resource must point at this module's own certificate, since that is the only thing tying the wait to the certificate whose records were written."
  }
}

run "the_default_covers_only_the_primary_domain" {
  command = plan

  assert {
    condition     = length(var.subject_alternative_names) == 0
    error_message = "subject_alternative_names must default to empty so a plain single-host certificate is what a consumer gets without asking; CarModPicker's api certificate and Portfolio's api certificate both rely on that default."
  }

  assert {
    condition     = aws_acm_certificate.this[0].subject_alternative_names == toset(["example-staging.com"])
    error_message = "With no extra names the certificate must cover the primary domain and nothing else. The AWS provider always folds domain_name into this attribute, so the covered set here is the primary domain alone."
  }

  assert {
    condition     = length(local.validation_records) <= length(aws_acm_certificate.this[0].subject_alternative_names)
    error_message = "There can never be more validation record keys than covered domains: the record map is keyed by the domain each option belongs to, so a key with no covered domain behind it would be a record ACM never asked for."
  }
}

run "a_certificate_with_no_alternative_names_writes_exactly_one_validation_record" {
  command = plan

  assert {
    condition     = length(local.validation_records) <= 1
    error_message = "A certificate covering one domain can ask for at most one validation record, and the record set is keyed by domain name so a single covered domain cannot produce two keys."
  }

  assert {
    condition     = alltrue([for r in aws_route53_record.validation : r.zone_id == "Z0EXAMPLESTAGING01"])
    error_message = "Every validation record must be written into the single zone_id the consumer named: ACM asks the parent resolvers for the record, so a record in the wrong zone never gets read and issuance hangs until it times out."
  }

  assert {
    condition     = alltrue([for r in aws_route53_record.validation : r.ttl == 60])
    error_message = "validation_record_ttl must default to 60 seconds: the record is written once and read by ACM within minutes, so a long TTL only lengthens how long a stale value is cached if the certificate is ever recreated."
  }

  assert {
    condition     = alltrue([for r in aws_route53_record.validation : r.allow_overwrite])
    error_message = "allow_overwrite must default to true: a certificate covering an apex and its wildcard gets two domain_validation_options entries carrying identical record data, so the second write would fail on an existing record without it."
  }
}

run "an_apex_and_its_wildcard_are_two_covered_domains_and_two_record_resources" {
  command = plan

  variables {
    domain_name               = "example-staging.com"
    subject_alternative_names = ["*.example-staging.com"]
  }

  assert {
    condition     = aws_acm_certificate.this[0].subject_alternative_names == toset(["*.example-staging.com", "example-staging.com"])
    error_message = "The alternative names must reach the certificate unchanged and the primary domain must remain covered alongside them, because that combined set is exactly the hosts the issued certificate is valid for. This is the shape CarModPicker's site certificate and Portfolio's www certificate both ask for."
  }

  assert {
    condition     = length(aws_acm_certificate.this[0].subject_alternative_names) == 2
    error_message = "An apex plus its wildcard must be two covered domains: ACM proves both with a single CNAME but reports one domain_validation_options entry each, which is why the records are keyed by domain and allow_overwrite defaults to true."
  }
}

run "the_ttl_reaches_every_validation_record" {
  command = plan

  variables {
    validation_record_ttl = 300
  }

  assert {
    condition     = alltrue([for r in aws_route53_record.validation : r.ttl == 300])
    error_message = "An explicit validation_record_ttl must reach every record and not just the first, since a certificate covering several domains writes several records and they must all behave the same."
  }
}

run "overwrite_can_be_turned_off_for_a_zone_that_must_not_be_taken_over" {
  command = plan

  variables {
    allow_overwrite = false
  }

  assert {
    condition     = alltrue([for r in aws_route53_record.validation : !r.allow_overwrite])
    error_message = "allow_overwrite = false must reach every record: a consumer sharing a zone with records managed elsewhere needs Terraform to fail loudly rather than quietly clobber a record it did not create."
  }
}

run "tags_reach_the_certificate_and_nothing_else_takes_tags" {
  command = plan

  variables {
    tags = {
      Environment = "example-staging"
      Component   = "certificate"
    }
  }

  assert {
    condition     = aws_acm_certificate.this[0].tags["Environment"] == "example-staging"
    error_message = "Tags must reach the certificate so cost and ownership reporting can attribute it; the certificate is the only taggable resource in this module."
  }

  assert {
    condition     = aws_acm_certificate.this[0].tags["Component"] == "certificate"
    error_message = "Every key in the tags map must reach the certificate, not just the first, because a partial merge would leave resources half attributed with nothing to show it."
  }
}

run "disabling_the_module_plans_nothing_at_all" {
  command = plan

  variables {
    enabled = false
    zone_id = null
  }

  assert {
    condition     = length(aws_acm_certificate.this) == 0
    error_message = "enabled = false must plan no certificate: an environment that serves no custom domain must not pay for a certificate that can never validate."
  }

  assert {
    condition     = length(aws_route53_record.validation) == 0
    error_message = "enabled = false must write no validation records, or a disabled environment would still be mutating a hosted zone it does not serve from."
  }

  assert {
    condition     = length(aws_acm_certificate_validation.this) == 0
    error_message = "enabled = false must plan no validation resource: a wait for issuance with no certificate behind it would block every apply forever."
  }

  assert {
    condition     = local.count == 0
    error_message = "local.count is the single gate every resource in the module counts on, so it must be zero when the module is disabled."
  }
}

run "a_disabled_module_needs_no_zone_id_at_all" {
  command = plan

  variables {
    enabled = false
    zone_id = null
  }

  assert {
    condition     = length(local.validation_records) == 0
    error_message = "With the module disabled there is nothing to validate, so the validation record map must be empty rather than reaching into a certificate that was never planned."
  }
}
