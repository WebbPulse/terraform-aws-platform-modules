variables {
  name = "example-dns-api"

  integrations = {
    app = {
      lambda_function_name = "example-dns-api"
      lambda_invoke_arn    = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-dns-api/invocations"
      timeout_milliseconds = 29000
    }
  }

  default_integration = "app"

  domain_name     = "api.example.com"
  certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/11111111-2222-3333-4444-555555555555"
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

run "default_derives_the_record_from_zone_id" {
  command = plan

  variables {
    zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = length(aws_route53_record.alias) == 1
    error_message = "Leaving dns_record_enabled null must keep the historic behaviour: a domain_name plus a zone_id writes the alias record."
  }
}

run "default_writes_no_record_without_a_zone_id" {
  command = plan

  assert {
    condition     = length(aws_route53_record.alias) == 0
    error_message = "A consumer that writes the record itself passes no zone_id and must still get no alias record from the module."
  }
}

run "enabled_false_suppresses_the_record_despite_a_zone_id" {
  command = plan

  variables {
    zone_id            = "Z0123456789ABCDEFGHIJ"
    dns_record_enabled = false
  }

  assert {
    condition     = length(aws_route53_record.alias) == 0
    error_message = "dns_record_enabled false must win over a non null zone_id, so a consumer can hold the record back for an apply."
  }
}

run "enabled_true_plans_the_record_from_a_known_boolean" {
  command = plan

  variables {
    zone_id            = "Z0123456789ABCDEFGHIJ"
    dns_record_enabled = true
  }

  assert {
    condition     = length(aws_route53_record.alias) == 1
    error_message = "dns_record_enabled true must plan the alias record, which is what lets a fresh account create the zone and the record in one apply."
  }
}

run "enabled_true_without_a_domain_name_is_rejected" {
  command = plan

  variables {
    domain_name        = null
    certificate_arn    = null
    zone_id            = null
    dns_record_enabled = true
  }

  expect_failures = [var.dns_record_enabled]
}
