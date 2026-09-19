variables {
  name_prefix = "example-staging"
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

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

run "a_name_prefix_with_a_space_is_rejected" {
  command = plan

  variables {
    name_prefix = "example staging"
  }

  expect_failures = [var.name_prefix]
}

run "a_sampling_percentage_above_one_hundred_is_rejected" {
  command = plan

  variables {
    indexing_rule_sampling_percentage = 101
  }

  expect_failures = [var.indexing_rule_sampling_percentage]
}

run "a_negative_sampling_percentage_is_rejected" {
  command = plan

  variables {
    indexing_rule_sampling_percentage = -1
  }

  expect_failures = [var.indexing_rule_sampling_percentage]
}
