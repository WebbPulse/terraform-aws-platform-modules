variables {
  name = "example-staging"

  notification_emails = ["tyler@webbpulse.com"]

  resource_group_description = "All Example managed resources"

  resource_group_tag_filters = {
    Project = ["example"]
  }
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

run "the_group_takes_the_name_and_description_the_consumer_gave" {
  command = plan

  assert {
    condition     = length(aws_resourcegroups_group.this) == 1
    error_message = "The resource group must default to on. It is the console entry point an operator uses to see everything the estate owns, and both estates rely on the default."
  }

  assert {
    condition     = one(aws_resourcegroups_group.this[*].name) == "example-staging"
    error_message = "The group must be named with var.name verbatim. A resource group name cannot be changed in place, so a suffix appended here would force a destroy and recreate on every existing estate."
  }

  assert {
    condition     = one(aws_resourcegroups_group.this[*].description) == "All Example managed resources"
    error_message = "The description must be stored as written. It is the only human explanation of what the group covers and both estates set it."
  }
}

run "the_tag_query_matches_only_the_tags_the_consumer_named" {
  command = plan

  assert {
    condition     = jsondecode(local.resource_query).TagFilters == [{ Key = "Project", Values = ["example"] }]
    error_message = "A tag filter must render as one { Key, Values } object per map entry. The group's membership is entirely decided by this query, so a mis-shaped filter produces a group that silently matches nothing."
  }

  assert {
    condition     = jsondecode(local.resource_query).ResourceTypeFilters == ["AWS::AllSupported"]
    error_message = "ResourceTypeFilters must default to AWS::AllSupported, which is what makes the group project wide. Any narrower default would quietly exclude services from the view an operator trusts as complete."
  }

  assert {
    condition     = one(one(aws_resourcegroups_group.this[*].resource_query)).query == local.resource_query
    error_message = "The rendered query must be the one attached to the group. If the two ever diverge, the tests below assert on a string that never reaches AWS."
  }
}

run "a_tag_filter_accepting_several_values_renders_them_all" {
  command = plan

  variables {
    resource_group_tag_filters = {
      Project     = ["example", "example-legacy"]
      Environment = ["staging"]
    }
  }

  assert {
    condition     = length(jsondecode(local.resource_query).TagFilters) == 2
    error_message = "Every key in resource_group_tag_filters must become its own TagFilter. Dropping one silently widens or narrows the group, depending on which key was lost."
  }

  assert {
    condition = one([
      for filter in jsondecode(local.resource_query).TagFilters : filter.Values if filter.Key == "Project"
    ]) == ["example", "example-legacy"]
    error_message = "A key listing several accepted values must keep all of them, in order. That is how a group spans a project mid rename without the two halves becoming separate groups."
  }

  assert {
    condition = one([
      for filter in jsondecode(local.resource_query).TagFilters : filter.Values if filter.Key == "Environment"
    ]) == ["staging"]
    error_message = "A second tag key must carry its own values rather than inheriting the first key's. Tag filters combine, so a leaked value list changes which resources the group contains."
  }
}

run "a_narrowed_resource_type_filter_replaces_the_catch_all" {
  command = plan

  variables {
    resource_group_resource_type_filters = ["AWS::Lambda::Function", "AWS::DynamoDB::Table"]
  }

  assert {
    condition     = jsondecode(local.resource_query).ResourceTypeFilters == ["AWS::Lambda::Function", "AWS::DynamoDB::Table"]
    error_message = "An explicit resource type list must replace AWS::AllSupported rather than merge with it. Merging would make the narrowing a no-op and quietly return a group the consumer asked to restrict."
  }
}

run "tags_are_passed_through_when_the_consumer_sets_them" {
  command = plan

  variables {
    tags = {
      Project   = "example"
      ManagedBy = "terraform"
    }
  }

  assert {
    condition     = local.resource_group_tags == tomap({ Project = "example", ManagedBy = "terraform" })
    error_message = "A non empty tags map must reach the group as given. These tags sit on top of provider default_tags and are what make the group itself discoverable by the same conventions as the resources it contains."
  }

  assert {
    condition     = one(aws_resourcegroups_group.this[*].tags) == tomap({ Project = "example", ManagedBy = "terraform" })
    error_message = "The tags local must actually be attached to the group, or the assertion above measures a value that never reaches AWS."
  }
}

run "an_empty_tags_map_is_passed_as_null_rather_than_an_empty_map" {
  command = plan

  assert {
    condition     = local.resource_group_tags == null
    error_message = "An empty tags map must become null. A group that never set tags stores null, so passing an empty map instead would produce a perpetual diff on every estate that does not tag the group."
  }

  assert {
    condition     = one(aws_resourcegroups_group.this[*].tags) == null
    error_message = "The null must reach the resource, which is what makes the module plan clean against a group adopted from the console."
  }
}

run "a_null_description_leaves_the_argument_unset" {
  command = plan

  variables {
    resource_group_description = null
  }

  assert {
    condition     = one(aws_resourcegroups_group.this[*].description) == null
    error_message = "A null description must stay null rather than becoming an empty string, because that is what a group created without a description stores and anything else is a diff on adoption."
  }
}

run "turning_the_resource_group_off_removes_it_and_nulls_both_outputs" {
  command = plan

  variables {
    resource_group_enabled     = false
    resource_group_tag_filters = {}
  }

  assert {
    condition     = length(aws_resourcegroups_group.this) == 0
    error_message = "An account that already groups its resources another way must be able to switch this off, so the group has to disappear entirely rather than be created empty."
  }

  assert {
    condition     = output.resource_group_arn == null
    error_message = "resource_group_arn must be null rather than an error when the group is off, so a consumer can reference it unconditionally in an output."
  }

  assert {
    condition     = output.resource_group_name == null
    error_message = "resource_group_name must be null when the group is off. It doubles as the group's id, and a consumer building a console link must be able to test it for null."
  }
}

run "an_enabled_group_with_no_tag_filters_is_rejected" {
  command = plan

  variables {
    resource_group_tag_filters = {}
  }

  expect_failures = [var.resource_group_tag_filters]
}

run "a_tag_key_with_no_accepted_values_is_rejected" {
  command = plan

  variables {
    resource_group_tag_filters = {
      Project = []
    }
  }

  expect_failures = [var.resource_group_tag_filters]
}

run "an_empty_resource_type_filter_list_is_rejected" {
  command = plan

  variables {
    resource_group_resource_type_filters = []
  }

  expect_failures = [var.resource_group_resource_type_filters]
}
