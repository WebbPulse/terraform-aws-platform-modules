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

run "the_default_is_a_child_zone_plus_one_ns_delegation_in_the_parent" {
  command = plan

  assert {
    condition     = length(aws_route53_zone.this) == 1
    error_message = "enabled defaults to true, so a consumer passing only zone_name and parent_zone_id must get exactly one hosted zone."
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 1
    error_message = "delegate defaults to true, so the staging case gets its NS record without asking: a child zone nothing delegates to is invisible to every resolver on the internet."
  }

  assert {
    condition     = aws_route53_zone.this[0].name == "staging.example.com"
    error_message = "zone_name must reach aws_route53_zone.name verbatim and with no trailing dot added, because an adopted zone keeps its exact stored name and any rewriting here would plan a replacement of a live zone."
  }

  assert {
    condition     = aws_route53_record.delegation[0].name == "staging.example.com"
    error_message = "The delegation record must be named for the child zone itself: an NS record at any other name delegates a domain nobody asked for and leaves the child unreachable."
  }

  assert {
    condition     = aws_route53_record.delegation[0].type == "NS"
    error_message = "The delegation must be an NS record and nothing else: NS is the only record type that hands a subtree of the namespace to another set of name servers."
  }

  assert {
    condition     = aws_route53_record.delegation[0].zone_id == "Z0EXAMPLEPARENT01"
    error_message = "The delegation must be written into parent_zone_id, which is the zone the aws.parent provider authenticates to; writing it into the child zone would delegate the child to itself and resolve nothing."
  }
}

run "the_delegation_points_at_the_name_servers_route53_assigned_to_the_new_zone" {
  command = plan

  override_resource {
    target          = aws_route53_zone.this
    override_during = plan
    values = {
      name_servers = ["ns-1.awsdns-01.com", "ns-2.awsdns-02.net", "ns-3.awsdns-03.org", "ns-4.awsdns-04.co.uk"]
    }
  }

  assert {
    condition     = toset(aws_route53_record.delegation[0].records) == toset(aws_route53_zone.this[0].name_servers)
    error_message = "The NS record must carry exactly the name servers of the zone this module created: hardcoding or reordering them anywhere else would point the parent at servers that do not host the child."
  }

  assert {
    condition     = aws_route53_record.delegation[0].ttl == 300
    error_message = "delegation_ttl must default to 300 seconds, which is short enough that recreating a staging zone becomes resolvable in minutes rather than caching a dead delegation for hours."
  }
}

run "the_zone_defaults_leave_every_optional_attribute_to_the_provider" {
  command = plan

  assert {
    condition     = aws_route53_zone.this[0].comment == null || aws_route53_zone.this[0].comment == "Managed by Terraform"
    error_message = "comment must default to unset so the provider writes its own \"Managed by Terraform\": an adopted zone created without a comment already carries that value, and setting anything else would plan a diff on a live zone."
  }

  assert {
    condition     = aws_route53_zone.this[0].force_destroy == false
    error_message = "force_destroy must default to false so destroying this module can never silently delete records that were added to the zone outside Terraform."
  }

  assert {
    condition     = local.zone_tags == null
    error_message = "An empty tags map must be passed as null rather than an empty map, so the zone plans identically to one that never set tags at all and adoption stays a pure state move."
  }
}

run "an_explicit_comment_force_destroy_and_tags_all_reach_the_zone" {
  command = plan

  variables {
    comment        = "example-staging child zone"
    force_destroy  = true
    delegation_ttl = 60

    tags = {
      Environment = "example-staging"
      Component   = "dns"
    }
  }

  assert {
    condition     = aws_route53_zone.this[0].comment == "example-staging child zone"
    error_message = "An explicit comment must reach the zone, since the comment is the only human readable label the Route 53 console shows next to a hosted zone id."
  }

  assert {
    condition     = aws_route53_zone.this[0].force_destroy == true
    error_message = "force_destroy must be settable: an ephemeral staging zone full of Terraform managed records has to be destroyable without a manual console sweep first."
  }

  assert {
    condition     = aws_route53_zone.this[0].tags["Environment"] == "example-staging"
    error_message = "Tags must reach the zone so cost and ownership reporting can attribute it alongside the rest of the environment."
  }

  assert {
    condition     = aws_route53_zone.this[0].tags["Component"] == "dns"
    error_message = "Every key in the tags map must reach the zone, not just the first, or a partial merge would leave the zone half attributed with nothing to show it."
  }

  assert {
    condition     = aws_route53_record.delegation[0].ttl == 60
    error_message = "An explicit delegation_ttl must reach the NS record: lowering it ahead of a planned zone recreation is the only way to shorten how long resolvers cache the old delegation."
  }
}

run "delegate_false_creates_the_zone_but_writes_nothing_into_the_parent" {
  command = plan

  variables {
    delegate       = false
    parent_zone_id = null
  }

  assert {
    condition     = length(aws_route53_zone.this) == 1
    error_message = "delegate = false must still create the zone: the apex case owns a zone whose NS records are held by the registrar, and it needs the zone without the module touching any parent."
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 0
    error_message = "delegate = false must write no NS record, which is the whole point of the mode: the module must not need credentials into a parent account it is not delegating from."
  }

  assert {
    condition     = local.delegation_count == 0
    error_message = "local.delegation_count is the gate the delegation record counts on, so it must be zero whenever delegate is false."
  }
}

run "disabling_the_module_plans_nothing_at_all" {
  command = plan

  variables {
    enabled        = false
    parent_zone_id = null
  }

  assert {
    condition     = length(aws_route53_zone.this) == 0
    error_message = "enabled = false must plan no zone: a production workspace whose apex zone is owned by another workspace consumes this module purely as a no-op and must not create a second competing zone for the same name."
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 0
    error_message = "enabled = false must write no NS record, or a disabled module would delegate a name to a zone it never created."
  }

  assert {
    condition     = local.zone_count == 0 && local.delegation_count == 0
    error_message = "enabled gates both counts, so disabling the module must zero the delegation as well as the zone even though delegate is still at its true default."
  }
}

run "a_disabled_module_needs_neither_a_parent_zone_nor_a_delegation_decision" {
  command = plan

  variables {
    enabled        = false
    delegate       = true
    parent_zone_id = null
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 0
    error_message = "enabled = false with delegate still true must plan nothing: that combination is exactly what a consumer passing the same variables in every environment produces in production, and it must not demand a parent_zone_id there."
  }
}
