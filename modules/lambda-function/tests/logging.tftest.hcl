variables {
  function_name = "example-staging-api"

  runtime = "python3.13"
  handler = "app.lambda_handler.handler"

  code = {
    filename         = "placeholder.zip"
    source_code_hash = "3q2+7w=="
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

run "the_log_group_arn_output_comes_from_the_managed_group" {
  command = plan

  override_resource {
    target          = aws_cloudwatch_log_group.this
    override_during = plan
    values = {
      arn = "arn:aws:logs:us-west-2:123456789012:log-group:/aws/lambda/example-staging-api"
    }
  }

  assert {
    condition     = output.log_group_arn == "arn:aws:logs:us-west-2:123456789012:log-group:/aws/lambda/example-staging-api"
    error_message = "log_group_arn is what a runtime policy appends :* to in order to scope logs:CreateLogStream and logs:PutLogEvents to this function's own group; both consuming estates build that statement from it, so it must be the managed group's ARN and not an invented one."
  }
}

run "the_log_group_is_the_one_lambda_would_have_written_to_anyway" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/aws/lambda/example-staging-api"
    error_message = "With log_group_name left null the group must be /aws/lambda/<function_name>, which is the group Lambda creates on first invoke; any other name leaves the service writing to an unmanaged group with no retention while the managed one stays empty."
  }

  assert {
    condition     = output.log_group_name == "/aws/lambda/example-staging-api"
    error_message = "The log_group_name output feeds alarm metric filters in the consuming estates, so it must be the name of the group the function actually writes to."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.kms_key_id == null
    error_message = "With log_group_kms_key_id null the group must fall back to the CloudWatch Logs service key rather than being handed an empty key id, which the service rejects."
  }
}

run "an_explicit_log_group_name_replaces_the_derived_one" {
  command = plan

  variables {
    log_group_name = "/example/staging/api"

    log_group_kms_key_id = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"

    log_group_tags = {
      Retention = "short"
    }
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/example/staging/api"
    error_message = "An explicit log_group_name must replace the derived default outright rather than being appended to it, because a consumer adopting a group it already created needs the module to land on exactly that existing name."
  }

  assert {
    condition     = output.log_group_name == "/example/staging/api"
    error_message = "The output must follow the override, otherwise a consumer's alarm filters point at a group nothing writes to."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.kms_key_id == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "log_group_kms_key_id must reach the group: an estate required to encrypt logs with its own key has no other way to set it, and a silently dropped key leaves the logs on the service key."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.tags["Retention"] == "short"
    error_message = "log_group_tags must land on the log group alone; they are a separate input so a consumer can tag the group without those tags reaching the function or the role."
  }

  assert {
    condition     = length(var.tags) == 0
    error_message = "log_group_tags is a separate input from tags, so setting it must leave the function's own tag input untouched; a tag meant for a log group that reached the function would distort the cost reports both estates group by."
  }
}

run "the_chosen_retention_reaches_the_log_group" {
  command = plan

  variables {
    log_retention_days = 7
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days == 7
    error_message = "log_retention_days must reach the group unchanged; both consuming estates set 7 explicitly and a dropped value silently reverts to never expiring, which is an unbounded log bill nobody is alarmed about."
  }
}

run "a_retention_of_zero_means_never_expire" {
  command = plan

  variables {
    log_retention_days = 0
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days == 0
    error_message = "Zero must reach the group as zero rather than being coalesced away, because zero is how CloudWatch Logs spells never expire and a consumer keeping logs indefinitely has no other value to pass."
  }
}

run "the_module_default_retention_is_a_value_cloudwatch_accepts" {
  command = plan

  assert {
    condition = contains([
      0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096,
      1827, 2192, 2557, 2922, 3288, 3653,
    ], aws_cloudwatch_log_group.this.retention_in_days)
    error_message = "Whatever the default retention is, it must be one of the values CloudWatch Logs accepts; the service rejects anything else at apply, so a default outside the set would break every consumer that never sets the variable."
  }
}

run "a_retention_cloudwatch_does_not_accept_is_rejected" {
  command = plan

  variables {
    log_retention_days = 10
  }

  expect_failures = [var.log_retention_days]
}

run "a_negative_retention_is_rejected" {
  command = plan

  variables {
    log_retention_days = -1
  }

  expect_failures = [var.log_retention_days]
}

run "the_logging_config_defaults_to_json_without_naming_the_group" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.logging_config[0].log_format == "JSON"
    error_message = "log_format must default to JSON, because JSON is what makes application_log_level and system_log_level available at all; Text silently ignores both."
  }

  assert {
    condition     = !var.set_logging_config_log_group
    error_message = "set_logging_config_log_group must default to false, which leaves log_group out of the logging_config; both values point at the same group, so flipping it is an in place update of the function and an estate with the field unset in state must see an empty plan."
  }

  assert {
    condition     = aws_lambda_function.this.logging_config[0].application_log_level == null
    error_message = "application_log_level must default to null so an estate whose function has no level in state adopts the module without a diff."
  }

  assert {
    condition     = aws_lambda_function.this.logging_config[0].system_log_level == null
    error_message = "system_log_level must default to null for the same reason: the module has to reproduce the shape both estates already run before it can change it."
  }
}

run "naming_the_group_in_the_logging_config_points_at_the_managed_group" {
  command = plan

  variables {
    log_format                   = "JSON"
    application_log_level        = "INFO"
    system_log_level             = "INFO"
    set_logging_config_log_group = true
  }

  assert {
    condition     = aws_lambda_function.this.logging_config[0].log_group == "/aws/lambda/example-staging-api"
    error_message = "With set_logging_config_log_group on, the function must name the module's own log group, not a second one; pointing the function at a group the module does not manage leaves the retention unenforced."
  }

  assert {
    condition     = aws_lambda_function.this.logging_config[0].application_log_level == "INFO"
    error_message = "application_log_level must reach the function: it is the filter that decides which application logs the service forwards at all, and both consuming estates set it to INFO."
  }

  assert {
    condition     = aws_lambda_function.this.logging_config[0].system_log_level == "INFO"
    error_message = "system_log_level must reach the function; it controls Lambda's own platform logs, which are what a cold start or an init failure is diagnosed from."
  }
}

run "a_text_format_function_keeps_the_levels_out" {
  command = plan

  variables {
    log_format = "Text"
  }

  assert {
    condition     = aws_lambda_function.this.logging_config[0].log_format == "Text"
    error_message = "Text must reach the function: it is the shape one of the two estates has in state, and the module has to reproduce it before it can move that estate to JSON."
  }
}

run "a_log_format_lambda_does_not_offer_is_rejected" {
  command = plan

  variables {
    log_format = "Structured"
  }

  expect_failures = [var.log_format]
}

run "an_application_log_level_lambda_does_not_offer_is_rejected" {
  command = plan

  variables {
    application_log_level = "VERBOSE"
  }

  expect_failures = [var.application_log_level]
}

run "a_system_log_level_lambda_does_not_offer_is_rejected" {
  command = plan

  variables {
    system_log_level = "TRACE"
  }

  expect_failures = [var.system_log_level]
}
