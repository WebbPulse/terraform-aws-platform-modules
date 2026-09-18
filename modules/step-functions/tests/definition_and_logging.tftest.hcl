variables {
  name = "example-staging-run"

  definition = "{\"Comment\":\"example\",\"StartAt\":\"Done\",\"States\":{\"Done\":{\"Type\":\"Succeed\"}}}"
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

override_resource {
  target          = aws_sfn_state_machine.this
  override_during = plan
  values = {
    arn = "arn:aws:states:us-west-2:123456789012:stateMachine:example-staging-run"
  }
}

run "the_machine_is_standard_and_carries_the_definition_unchanged" {
  command = plan

  assert {
    condition     = aws_sfn_state_machine.this.type == "STANDARD"
    error_message = "type must default to STANDARD: it is the only type with a durable execution history, exactly-once semantics and the task-token callbacks a .sync or waitForTaskToken state depends on, so an EXPRESS default would silently break the orchestration this module exists for."
  }

  assert {
    condition     = aws_sfn_state_machine.this.definition == var.definition
    error_message = "With no substitutions the definition must reach the service byte for byte; rewriting a definition a consumer has already validated against the Amazon States Language is a change nobody asked for."
  }

  assert {
    condition     = !aws_sfn_state_machine.this.publish
    error_message = "publish must default to false. A control plane that always runs the current definition has no use for a numbered version, and publishing one on every change grows a version list that has to be pruned by hand."
  }
}

run "substitutions_replace_the_placeholders_before_the_service_sees_them" {
  command = plan

  variables {
    definition = "{\"StartAt\":\"Run\",\"States\":{\"Run\":{\"Type\":\"Task\",\"Resource\":\"arn:aws:states:::ecs:runTask.sync\",\"Parameters\":{\"TaskDefinition\":\"$${TaskDefinitionArn}\"},\"End\":true}}}"

    definition_substitutions = {
      TaskDefinitionArn = "arn:aws:ecs:us-west-2:123456789012:task-definition/example-plan:3"
    }
  }

  assert {
    condition     = strcontains(aws_sfn_state_machine.this.definition, "arn:aws:ecs:us-west-2:123456789012:task-definition/example-plan:3")
    error_message = "A definition_substitutions entry must be substituted into the definition, because that is the only way a definition held in a file can name a task definition ARN Terraform computes at apply."
  }

  assert {
    condition     = !strcontains(aws_sfn_state_machine.this.definition, "TaskDefinitionArn")
    error_message = "No placeholder may survive substitution: a literal $${...} left in the definition is rejected at apply by the service's own validation, which reports a malformed ARN rather than a missing substitution."
  }

  assert {
    condition     = can(jsondecode(aws_sfn_state_machine.this.definition))
    error_message = "The substituted definition must still be valid JSON; substitution happens inside a quoted string, so a value carrying a bare quote would corrupt the document."
  }
}

run "the_log_group_defaults_to_the_vendedlogs_prefix" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/aws/vendedlogs/states/example-staging-run"
    error_message = "With log_group_name left null the group must be /aws/vendedlogs/states/<name>. Step Functions delivers through vended log delivery, and that prefix is the one the service's own console creates and the cheapest destination for it."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days == 14
    error_message = "log_retention_days must default to 14. An execution history expires after 90 days on its own, so the log group is the durable record and an unset retention would keep it forever at full price."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.kms_key_id == null
    error_message = "With log_group_kms_key_id null the group must fall back to the CloudWatch Logs service key rather than being handed an empty key id, which the service rejects."
  }
}

run "the_logging_destination_is_the_managed_group_with_the_wildcard_suffix" {
  command = plan

  override_resource {
    target          = aws_cloudwatch_log_group.this
    override_during = plan
    values = {
      arn = "arn:aws:logs:us-west-2:123456789012:log-group:/aws/vendedlogs/states/example-staging-run"
    }
  }

  assert {
    condition     = aws_sfn_state_machine.this.logging_configuration[0].log_destination == "arn:aws:logs:us-west-2:123456789012:log-group:/aws/vendedlogs/states/example-staging-run:*"
    error_message = "The log destination must be the managed group's ARN with :* appended. Step Functions rejects a bare log group ARN here, and the error names an invalid ARN rather than the missing suffix, so it is worth asserting."
  }

  assert {
    condition     = aws_sfn_state_machine.this.logging_configuration[0].level == "ALL"
    error_message = "log_level must default to ALL: the execution history is the only record of what a run did and it expires after 90 days, so a machine logging only failures cannot answer what a successful run changed."
  }

  assert {
    condition     = aws_sfn_state_machine.this.logging_configuration[0].include_execution_data
    error_message = "include_execution_data must default to true, otherwise a failed run logs that a state failed without logging what it was given, which is the one thing needed to reproduce it."
  }
}

run "logging_off_leaves_no_destination" {
  command = plan

  variables {
    log_level              = "OFF"
    include_execution_data = false
  }

  assert {
    condition     = aws_sfn_state_machine.this.logging_configuration[0].level == "OFF"
    error_message = "OFF must reach the service, so a consumer that has decided execution logging is not worth the ingest cost can turn it off without dropping the logging_configuration block entirely."
  }

  assert {
    condition     = aws_sfn_state_machine.this.logging_configuration[0].log_destination == null
    error_message = "With the level OFF the destination must be null: Step Functions rejects a logging_configuration that names a destination while logging nothing."
  }

  assert {
    condition     = !aws_sfn_state_machine.this.logging_configuration[0].include_execution_data
    error_message = "include_execution_data false must reach the service; it is how a machine whose payloads carry material that must not be logged keeps them out of CloudWatch Logs, which has no redaction of its own."
  }
}

run "an_explicit_log_group_name_and_retention_replace_the_defaults" {
  command = plan

  variables {
    log_group_name       = "/example/staging/run"
    log_retention_days   = 7
    log_group_kms_key_id = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"

    log_group_tags = {
      Retention = "short"
    }
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/example/staging/run"
    error_message = "An explicit log_group_name must replace the derived default outright, because a consumer adopting a group it already created needs the module to land on exactly that existing name."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days == 7
    error_message = "log_retention_days must reach the group unchanged; a dropped value silently reverts to never expiring, which is an unbounded log bill nobody is alarmed about."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.kms_key_id == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "log_group_kms_key_id must reach the group: an estate required to encrypt logs with its own key has no other way to set it, and a silently dropped key leaves the logs on the service key."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.tags["Retention"] == "short"
    error_message = "log_group_tags must land on the log group alone; they are a separate input so a consumer can tag the group without those tags reaching the state machine or the role."
  }

  assert {
    condition     = length(var.tags) == 0
    error_message = "log_group_tags must not leak onto the state machine: tags there drive cost allocation, and copying the group's tags across changes what a consumer's reports count."
  }
}

run "a_definition_that_is_not_json_is_rejected" {
  command = plan

  variables {
    definition = "{\"StartAt\":\"Done\",}"
  }

  expect_failures = [var.definition]
}

run "a_definition_without_a_states_object_is_rejected" {
  command = plan

  variables {
    definition = "{\"Comment\":\"no states here\",\"StartAt\":\"Done\"}"
  }

  expect_failures = [var.definition]
}

run "a_retention_cloudwatch_does_not_accept_is_rejected" {
  command = plan

  variables {
    log_retention_days = 10
  }

  expect_failures = [var.log_retention_days]
}

run "a_log_level_step_functions_does_not_offer_is_rejected" {
  command = plan

  variables {
    log_level = "DEBUG"
  }

  expect_failures = [var.log_level]
}

run "a_state_machine_type_step_functions_does_not_offer_is_rejected" {
  command = plan

  variables {
    type = "SYNC"
  }

  expect_failures = [var.type]
}

run "a_name_with_a_character_the_module_rejects_is_rejected" {
  command = plan

  variables {
    name = "example staging run"
  }

  expect_failures = [var.name]
}
