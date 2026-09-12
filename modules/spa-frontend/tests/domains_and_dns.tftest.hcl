variables {
  name = "example-staging-frontend"
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "with_no_aliases_the_distribution_uses_the_cloudfront_certificate" {
  command = plan

  assert {
    condition     = length(coalesce(aws_cloudfront_distribution.this.aliases, [])) == 0
    error_message = "aliases defaults to empty, which is the shape a consumer gets before a certificate has been validated: the site must still plan and serve on the CloudFront hostname."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].cloudfront_default_certificate
    error_message = "Without alternate domain names the distribution must fall back to the default CloudFront certificate, because an ACM certificate is only legal on a distribution that actually claims the names it covers."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].acm_certificate_arn == null && aws_cloudfront_distribution.this.viewer_certificate[0].ssl_support_method == null
    error_message = "The custom certificate attributes must stay unset without aliases. CloudFront rejects a viewer certificate that names an ACM certificate or an SSL support method alongside the default certificate, so minimum_protocol_version is left to the provider and these two must be null."
  }

  assert {
    condition     = startswith(output.frontend_url, "https://")
    error_message = "frontend_url must always be an https URL, since it is what consumers paste into CORS allow lists and Cognito callback URLs."
  }
}

run "the_first_alias_is_canonical_and_carries_the_acm_certificate" {
  command = plan

  variables {
    aliases             = ["www.staging.example.com", "staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_cloudfront_distribution.this.aliases == toset(["www.staging.example.com", "staging.example.com"])
    error_message = "Every alias must reach the distribution, because CloudFront answers 403 for any host it does not claim, including the apex both consumers redirect from. The distribution stores them as a set, so the canonical ordering survives only in frontend_url."
  }

  assert {
    condition     = output.frontend_url == "https://www.staging.example.com"
    error_message = "frontend_url must be the first alias rather than the apex or the CloudFront hostname: both consumers list www first because that is the host viewers land on after the apex redirect."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].acm_certificate_arn == "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    error_message = "With aliases set the consumer's certificate must be attached, since the module deliberately does not create one and the distribution would otherwise serve a certificate for the wrong names."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].cloudfront_default_certificate == null
    error_message = "The default certificate flag must be cleared once a custom certificate is in use: setting both is rejected by CloudFront."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].ssl_support_method == "sni-only"
    error_message = "sni-only is required with a custom certificate; the alternative dedicated IP method costs hundreds of dollars a month and nothing here needs it."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2021"
    error_message = "The minimum TLS version must default to TLSv1.2_2021 so a new site never quietly accepts a weaker handshake than the estate's baseline."
  }
}

run "an_explicit_minimum_protocol_version_and_price_class_reach_the_distribution" {
  command = plan

  variables {
    aliases                  = ["staging.example.com"]
    acm_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    minimum_protocol_version = "TLSv1.3_2025"
    price_class              = "PriceClass_All"
    ipv6_enabled             = false
    comment                  = "example staging frontend"
  }

  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].minimum_protocol_version == "TLSv1.3_2025"
    error_message = "An explicit minimum_protocol_version must win over the default, so raising the floor for one environment is a one line change rather than a module fork."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.price_class == "PriceClass_All"
    error_message = "price_class must plumb through: PriceClass_100 is the cheap default, and a site with viewers outside North America and Europe needs the wider footprint."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.is_ipv6_enabled == false
    error_message = "ipv6_enabled must be able to turn IPv6 off, because a distribution that answers over IPv6 with no AAAA record is fine but one whose clients cannot reach it over IPv6 is not."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.comment == "example staging frontend"
    error_message = "comment must reach the distribution: it is the only human readable label in the CloudFront console list."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.enabled
    error_message = "The distribution must always be created enabled; a disabled distribution serves nothing and there is no input to ask for one."
  }
}

run "dns_records_are_not_created_unless_asked_for" {
  command = plan

  variables {
    aliases             = ["www.staging.example.com", "staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"

    dns_records = {
      www  = "www.staging.example.com"
      apex = "staging.example.com"
    }
  }

  assert {
    condition     = length(aws_route53_record.alias_a) == 0
    error_message = "create_dns_records defaults to false, so passing dns_records alone must create nothing. Portfolio's zone lives in another account, and this module writing into it with its own provider would fail the apply."
  }

  assert {
    condition     = length(aws_route53_record.alias_aaaa) == 0
    error_message = "No AAAA records may appear either while create_dns_records is false."
  }
}

run "create_dns_records_makes_one_a_record_per_label_and_no_aaaa" {
  command = plan

  variables {
    aliases             = ["www.staging.example.com", "staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    create_dns_records  = true
    zone_id             = "Z0123456789ABCDEFGHIJ"

    dns_records = {
      www  = "www.staging.example.com"
      apex = "staging.example.com"
    }
  }

  assert {
    condition     = length(aws_route53_record.alias_a) == 2
    error_message = "One A record must be created per entry in dns_records, which is how CarModPicker points both www and the apex at the distribution."
  }

  assert {
    condition     = aws_route53_record.alias_a["www"].name == "www.staging.example.com" && aws_route53_record.alias_a["apex"].name == "staging.example.com"
    error_message = "The map key must be the resource index and the value the hostname. Keying on the label rather than the hostname is what keeps resource addresses identical across environments whose hostnames differ, so a rename of a domain is not a destroy and recreate."
  }

  assert {
    condition     = aws_route53_record.alias_a["www"].type == "A" && aws_route53_record.alias_a["www"].zone_id == "Z0123456789ABCDEFGHIJ"
    error_message = "Each record must be an A alias in the zone the consumer named, since the whole point of this branch is that the module owns the records."
  }

  assert {
    condition     = one(aws_route53_record.alias_a["www"].alias).evaluate_target_health == false
    error_message = "Alias target health evaluation must be off: CloudFront is a global service with no health check to evaluate, and turning it on would make Route 53 fail the record."
  }

  assert {
    condition     = length(aws_route53_record.alias_aaaa) == 0
    error_message = "create_aaaa_records defaults to false, so turning on DNS management alone must not add AAAA records to an estate that only has A records today."
  }
}

run "create_aaaa_records_adds_a_matching_aaaa_for_every_label" {
  command = plan

  variables {
    aliases             = ["www.staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    create_dns_records  = true
    create_aaaa_records = true
    zone_id             = "Z0123456789ABCDEFGHIJ"

    dns_records = {
      www = "www.staging.example.com"
    }
  }

  assert {
    condition     = length(aws_route53_record.alias_aaaa) == 1 && length(aws_route53_record.alias_a) == 1
    error_message = "AAAA records must be a pure addition alongside the A records rather than a replacement, so turning the switch on never removes the IPv4 answer."
  }

  assert {
    condition     = aws_route53_record.alias_aaaa["www"].type == "AAAA" && aws_route53_record.alias_aaaa["www"].name == "www.staging.example.com"
    error_message = "The AAAA record must use the same label index and the same hostname as its A counterpart, otherwise the two answers drift apart."
  }
}

run "an_alias_that_is_not_a_hostname_is_rejected" {
  command = plan

  variables {
    aliases             = ["https://staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [var.aliases]
}

run "a_duplicated_alias_is_rejected" {
  command = plan

  variables {
    aliases             = ["staging.example.com", "staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [var.aliases]
}

run "aliases_without_a_certificate_are_rejected" {
  command = plan

  variables {
    aliases = ["staging.example.com"]
  }

  expect_failures = [var.acm_certificate_arn]
}

run "a_certificate_outside_us_east_1_is_rejected" {
  command = plan

  variables {
    aliases             = ["staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [var.acm_certificate_arn]
}

run "an_unsupported_minimum_protocol_version_is_rejected" {
  command = plan

  variables {
    minimum_protocol_version = "TLSv1.1_2016"
  }

  expect_failures = [var.minimum_protocol_version]
}

run "an_unsupported_price_class_is_rejected" {
  command = plan

  variables {
    price_class = "PriceClass_300"
  }

  expect_failures = [var.price_class]
}

run "managing_dns_without_a_zone_id_is_rejected" {
  command = plan

  variables {
    aliases             = ["staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    create_dns_records  = true
    dns_records         = { apex = "staging.example.com" }
  }

  expect_failures = [var.zone_id]
}

run "managing_dns_with_no_records_named_is_rejected" {
  command = plan

  variables {
    create_dns_records = true
    zone_id            = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [var.dns_records]
}

run "a_dns_record_for_a_hostname_that_is_not_an_alias_is_rejected" {
  command = plan

  variables {
    aliases             = ["www.staging.example.com"]
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    create_dns_records  = true
    zone_id             = "Z0123456789ABCDEFGHIJ"

    dns_records = {
      apex = "staging.example.com"
    }
  }

  expect_failures = [var.dns_records]
}

run "a_dns_record_label_that_cannot_be_a_resource_index_is_rejected" {
  command = plan

  variables {
    dns_records = {
      "www.staging" = "www.staging.example.com"
    }
  }

  expect_failures = [var.dns_records]
}
