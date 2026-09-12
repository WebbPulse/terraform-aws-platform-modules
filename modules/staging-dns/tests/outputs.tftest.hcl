variables {
  zone_name      = "staging.example.com"
  parent_zone_id = "Z0EXAMPLEPARENT01"
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

provider "aws" {
  alias                       = "parent"
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "the_zone_outputs_carry_the_stored_name_and_the_full_name_server_set" {
  command = plan

  override_resource {
    target          = aws_route53_zone.this
    override_during = plan
    values = {
      name_servers = ["ns-1.awsdns-01.com", "ns-2.awsdns-02.net", "ns-3.awsdns-03.org", "ns-4.awsdns-04.co.uk"]
    }
  }

  assert {
    condition     = output.zone_name == "staging.example.com"
    error_message = "zone_name must come back as the exact name Route 53 stores, with no trailing dot: CarModPicker and WebbPulse-Portfolio both build record names against the zone they were handed, and a name that differs by a dot from the stored one silently writes records into the wrong place."
  }

  assert {
    condition     = toset(output.name_servers) == toset(["ns-1.awsdns-01.com", "ns-2.awsdns-02.net", "ns-3.awsdns-03.org", "ns-4.awsdns-04.co.uk"])
    error_message = "name_servers must come back as exactly the name servers Route 53 assigned to this zone, with none dropped or substituted. Both applications publish it as a root output so an operator can compare it against the NS record actually live in the parent, and any filtering here would break that comparison."
  }

  assert {
    condition     = length(output.name_servers) == 4
    error_message = "A Route 53 hosted zone is always delegated to four name servers, and all four must reach the output: handing the parent fewer than the full set leaves the child resolvable only while those few respond."
  }
}

run "every_output_is_null_when_the_module_is_disabled" {
  command = plan

  variables {
    enabled        = false
    parent_zone_id = null
  }

  assert {
    condition     = output.zone_id == null
    error_message = "zone_id must be null rather than an error when disabled: both consumers feed it into a records_zone_id conditional in production, so evaluating the output must never fail there."
  }

  assert {
    condition     = output.zone_arn == null
    error_message = "zone_arn must be null when disabled, since one() over an empty count list is the whole reason every output in this module is null-safe."
  }

  assert {
    condition     = output.zone_name == null
    error_message = "zone_name must be null when disabled rather than echoing the zone_name input, which would claim a zone exists when none was created."
  }

  assert {
    condition     = output.name_servers == null
    error_message = "name_servers must be null when disabled: CarModPicker and WebbPulse-Portfolio both publish it as a root output in every environment, including ones where the module is off."
  }

  assert {
    condition     = output.delegation_record_fqdn == null
    error_message = "delegation_record_fqdn must be null when nothing was delegated, so a resource referencing it to order itself after the delegation is not handed a stale or invented name."
  }

  assert {
    condition     = output.delegation_record_id == null
    error_message = "delegation_record_id must be null when nothing was delegated rather than a constructed <parent_zone_id>_<zone_name>_NS string for a record that does not exist."
  }
}

run "the_delegation_outputs_are_null_when_the_zone_exists_but_is_not_delegated" {
  command = plan

  variables {
    delegate       = false
    parent_zone_id = null
  }

  override_resource {
    target          = aws_route53_zone.this
    override_during = plan
    values = {
      zone_id = "Z0EXAMPLESTAGING01"
    }
  }

  assert {
    condition     = output.zone_id == "Z0EXAMPLESTAGING01"
    error_message = "In zone-only mode zone_id must still be the created zone's own id, because that is the mode a consumer uses when the registrar holds the NS records and every record in the zone still resolves its zone_id through this output."
  }

  assert {
    condition     = output.delegation_record_fqdn == null
    error_message = "delegation_record_fqdn must be null in zone-only mode: nothing was written into a parent, so there is no FQDN to order anything against."
  }

  assert {
    condition     = output.delegation_record_id == null
    error_message = "delegation_record_id must be null in zone-only mode, since a record id for a record this module did not create would be a lie a consumer could import from."
  }
}

run "a_parent_zone_id_is_required_whenever_the_module_actually_delegates" {
  command = plan

  variables {
    enabled        = true
    delegate       = true
    parent_zone_id = null
  }

  expect_failures = [var.parent_zone_id]
}

run "an_empty_string_is_not_an_acceptable_parent_zone_id" {
  command = plan

  variables {
    enabled        = true
    delegate       = true
    parent_zone_id = ""
  }

  expect_failures = [var.parent_zone_id]
}

run "a_zone_name_with_a_trailing_dot_is_rejected" {
  command = plan

  variables {
    zone_name = "staging.example.com."
  }

  expect_failures = [var.zone_name]
}

run "a_single_label_zone_name_is_rejected" {
  command = plan

  variables {
    zone_name = "staging"
  }

  expect_failures = [var.zone_name]
}

run "an_uppercase_zone_name_is_rejected" {
  command = plan

  variables {
    zone_name = "Staging.Example.com"
  }

  expect_failures = [var.zone_name]
}

run "a_zero_delegation_ttl_is_rejected" {
  command = plan

  variables {
    delegation_ttl = 0
  }

  expect_failures = [var.delegation_ttl]
}

run "a_fractional_delegation_ttl_is_rejected" {
  command = plan

  variables {
    delegation_ttl = 60.5
  }

  expect_failures = [var.delegation_ttl]
}
