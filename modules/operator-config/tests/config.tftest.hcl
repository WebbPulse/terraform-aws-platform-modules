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

run "the_parameter_is_a_free_standard_string_seeded_with_an_empty_object" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.this.name == "/example-staging/config"
    error_message = "The parameter must be named /<name_prefix>/config, one per app and environment."
  }

  assert {
    condition     = aws_ssm_parameter.this.type == "String" && aws_ssm_parameter.this.tier == "Standard"
    error_message = "The parameter must be a Standard String: Standard is free, and String keeps the value readable without a KMS grant."
  }

  assert {
    condition     = aws_ssm_parameter.this.insecure_value == "{}"
    error_message = "The seed must be an empty JSON object, so the first plan decodes to an empty map."
  }

  assert {
    condition     = output.values == {}
    error_message = "A freshly seeded parameter must decode to an empty object, so a consumer's try(..., []) falls back to its default."
  }
}

run "an_explicit_name_overrides_the_prefix" {
  command = plan

  variables {
    name_prefix = null
    name        = "/carmodpicker/staging/config"
  }

  assert {
    condition     = output.name == "/carmodpicker/staging/config"
    error_message = "name must replace the derived name outright."
  }
}

run "neither_name_nor_prefix_is_rejected" {
  command = plan

  variables {
    name_prefix = null
  }

  expect_failures = [var.name]
}

run "a_prefix_with_a_leading_slash_is_rejected" {
  command = plan

  variables {
    name_prefix = "/example-staging"
  }

  expect_failures = [var.name_prefix]
}

run "a_name_without_a_leading_slash_is_rejected" {
  command = plan

  variables {
    name = "example-staging/config"
  }

  expect_failures = [var.name]
}
