# Plan-only regression test for the cty type unification failure in the repository policies.
#
# When publisher_principal_arns arrives from an aws_iam_role attribute the ARNs are unknown at plan
# time, so the publish statement's Principal.AWS is an unknown value of no settled type while the
# read statement's is a known string or list of strings. concat over the two objects asks Terraform
# to unify those attribute types and it cannot, so the plan fails with a cty type mismatch instead
# of leaving the statement unknown. Wrapping each statement in jsonencode inside the concat and
# jsondecode-ing each element after keeps the concat elements plain strings, so nothing unifies.
#
# The fixture wraps the module next to the roles it publishes with, because unknown values cannot
# cross between run blocks: a plan-only run block's outputs are themselves unknown. Nothing is
# created; every run block is command = plan against a mock provider, so this needs no credentials.

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

# Two publisher roles: Principal.AWS renders as a list.
run "unknown_publisher_arns_plan_as_a_list" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_publishers"
  }

  variables {
    publisher_role_count = 2
  }

  # Reaching an assertion at all is the regression check. Before the fix the plan failed inside the
  # concat, so no assertion in this block could run.
  assert {
    condition     = length(keys(module.codeartifact.repository_names)) == 3
    error_message = "Expected the module to plan all three repositories with unknown publisher ARNs."
  }
}

# One publisher role: Principal.AWS renders as a bare string. Same unknown value, the other branch
# of the one-or-many rendering.
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
