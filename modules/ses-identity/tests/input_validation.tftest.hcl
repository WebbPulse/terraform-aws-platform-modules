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
