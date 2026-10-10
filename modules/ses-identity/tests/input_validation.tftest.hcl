variables {
  configuration_set_name = "example-transactional"
  domain                 = "example.com"
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

run "neither_a_domain_nor_a_sender_address_is_rejected" {
  command = plan

  variables {
    domain         = null
    sender_address = null
  }

  expect_failures = [aws_sesv2_configuration_set.this]
}

run "both_a_domain_and_a_sender_address_are_rejected" {
  command = plan

  variables {
    domain         = "example.com"
    sender_address = "noreply@example.com"
  }

  expect_failures = [aws_sesv2_configuration_set.this]
}

run "dkim_records_without_a_zone_are_rejected" {
  command = plan

  variables {
    create_dkim_records = true
  }

  expect_failures = [aws_sesv2_configuration_set.this]
}

run "a_dmarc_record_without_a_zone_is_rejected" {
  command = plan

  variables {
    dmarc_record = "v=DMARC1; p=quarantine"
  }

  expect_failures = [aws_sesv2_configuration_set.this]
}

run "a_recipient_that_is_not_an_email_address_is_rejected" {
  command = plan

  variables {
    verified_recipients = ["not-an-address"]
  }

  expect_failures = [var.verified_recipients]
}

run "an_unknown_dkim_key_length_is_rejected" {
  command = plan

  variables {
    dkim_signing_key_length = "RSA_4096_BIT"
  }

  expect_failures = [var.dkim_signing_key_length]
}

run "mail_from_records_without_a_zone_are_rejected" {
  command = plan

  variables {
    mail_from_domain         = "bounce.example.com"
    create_mail_from_records = true
  }

  expect_failures = [aws_sesv2_configuration_set.this]
}

run "mail_from_records_without_a_mail_from_domain_are_rejected" {
  command = plan

  variables {
    dkim_records_zone_id     = "Z0123456789ABCDEFGHIJ"
    create_mail_from_records = true
  }

  expect_failures = [aws_sesv2_configuration_set.this]
}

run "mail_from_records_are_off_by_default" {
  command = plan

  variables {
    mail_from_domain     = "bounce.example.com"
    dkim_records_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = length(aws_route53_record.mail_from_mx) == 0 && length(aws_route53_record.mail_from_spf) == 0
    error_message = "No MAIL FROM records may be written unless create_mail_from_records is true, so existing callers plan no change."
  }
}

run "mail_from_records_point_at_the_regional_feedback_endpoint" {
  command = plan

  variables {
    mail_from_domain         = "bounce.example.com"
    dkim_records_zone_id     = "Z0123456789ABCDEFGHIJ"
    create_mail_from_records = true
  }

  assert {
    condition     = aws_route53_record.mail_from_mx[0].name == "bounce.example.com" && aws_route53_record.mail_from_mx[0].type == "MX"
    error_message = "The MAIL FROM MX record must sit at mail_from_domain."
  }

  assert {
    condition     = aws_route53_record.mail_from_mx[0].records == toset(["10 feedback-smtp.us-west-2.amazonses.com"])
    error_message = "The MAIL FROM MX record must point at the provider region's feedback-smtp endpoint."
  }

  assert {
    condition     = aws_route53_record.mail_from_spf[0].records == toset(["v=spf1 include:amazonses.com ~all"]) && aws_route53_record.mail_from_spf[0].type == "TXT"
    error_message = "The MAIL FROM SPF record must include amazonses.com."
  }

  assert {
    condition     = aws_route53_record.mail_from_mx[0].ttl == 300 && aws_route53_record.mail_from_spf[0].ttl == 300
    error_message = "The MAIL FROM records default to a 300 second TTL to match the hand written records they replace."
  }
}
