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
  target = module.ecs.data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = module.ecs.data.aws_partition.current
  values = {
    partition = "aws"
  }
}

override_data {
  target = module.ecs.data.aws_region.current
  values = {
    region = "us-west-2"
  }
}

run "a_task_statement_naming_an_apply_time_arn_still_plans" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_task_statements"
  }

  assert {
    condition     = length(keys(output.task_role_ids)) == 2
    error_message = "A task statement naming a log group ARN Terraform only knows at apply must not stop the module planning. Which tasks get an inline task policy is decided from the task keys alone, so the set of policy resources stays known however unknown a statement body is, and only the rendered document waits for apply."
  }

  assert {
    condition     = length(keys(output.task_definition_families)) == 2
    error_message = "Both task definitions must still plan alongside the unknown statement, so the unknown statement is confined to the policy document and does not reach any other for_each in the module."
  }
}
