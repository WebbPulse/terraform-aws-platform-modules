provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "unknown_publisher_arns_plan_as_a_list" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_publishers"
  }

  variables {
    publisher_role_count = 2
  }

  assert {
    condition     = length(keys(module.codeartifact.repository_names)) == 3
    error_message = "Expected the module to plan all three repositories with unknown publisher ARNs."
  }
}

run "unknown_publisher_arn_plans_as_a_bare_string" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_publishers"
  }

  variables {
    publisher_role_count = 1
  }

  assert {
    condition     = length(keys(module.codeartifact.repository_names)) == 3
    error_message = "Expected the module to plan all three repositories with a single unknown publisher ARN."
  }
}
